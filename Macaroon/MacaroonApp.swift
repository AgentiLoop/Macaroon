import SwiftUI
import UniformTypeIdentifiers
import Virtualization

@main
struct MacaroonApp: App {
    @StateObject private var vm = MacaroonVM()

    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
                .frame(minWidth: 1000, minHeight: 700)
                .task { await vm.loadCatalog() }
        }
    }
}

struct RestoreImage: Identifiable, Hashable {
    let version: String
    let build: String
    let url: URL
    var id: String { url.absoluteString }
    var title: String { "macOS \(version) (\(build))" }
}

struct Snapshot: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var hasState: Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent("State.vzvmsave").path) }
}

/// macOS guests use Apple's Mac platform; Linux and Windows ARM boot from an ISO through the generic EFI platform.
enum GuestOS: String, CaseIterable, Identifiable {
    case macOS, linux, windows
    var id: String { rawValue }
    var title: String { self == .macOS ? "macOS" : self == .linux ? "Linux" : "Windows ARM" }
    var folder: String { self == .macOS ? "VM" : self == .linux ? "Linux" : "Windows" }
}

@MainActor
final class MacaroonVM: NSObject, ObservableObject, VZVirtualMachineDelegate, URLSessionDownloadDelegate {
    @Published var images: [RestoreImage] = []
    @Published var selected: RestoreImage?
    @Published var status = "Loading Apple's IPSW list…"
    @Published var progress: Double?
    @Published var busy = false
    @Published var machine: VZVirtualMachine?
    @Published var running = false
    @Published var guest = GuestOS(rawValue: UserDefaults.standard.string(forKey: "guest") ?? "") ?? .macOS {
        didSet {
            UserDefaults.standard.set(guest.rawValue, forKey: "guest")
            loadSnapshots()
            status = isInstalled ? "\(guest.title) VM installed. Press Start." : guest == .macOS
                ? "Choose a macOS IPSW from Apple, then Download & Install."
                : "Choose an ARM64 \(guest.title) installer ISO."
        }
    }

    static let catalogURL = URL(string: "https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml")!
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Macaroon")
    var root: URL { base.appendingPathComponent(guest.folder) }
    var diskURL: URL { root.appendingPathComponent("Disk.img") }
    var auxURL: URL { root.appendingPathComponent("AuxiliaryStorage") }
    var modelURL: URL { root.appendingPathComponent("HardwareModel") }
    var machineIDURL: URL { root.appendingPathComponent("MachineIdentifier") }
    var macURL: URL { root.appendingPathComponent("MACAddress") }
    var ipswURL: URL { root.appendingPathComponent("Restore.ipsw") }
    var nvramURL: URL { root.appendingPathComponent("NVRAM") }
    var isoPathURL: URL { root.appendingPathComponent("ISOPath") }
    var sharedURL: URL { base.appendingPathComponent("VM/Shared") }
    var snapshotsURL: URL { root.appendingPathComponent("Snapshots") }
    @Published var snapshots: [Snapshot] = []
    var isInstalled: Bool { FileManager.default.fileExists(atPath: machineIDURL.path) }

    /// The installer ISO attached as a USB drive, if any.
    var installerISO: URL? {
        guard let path = try? String(contentsOf: isoPathURL, encoding: .utf8), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var installObservation: NSKeyValueObservation?

    override init() {
        super.init()
        try? FileManager.default.createDirectory(at: sharedURL, withIntermediateDirectories: true)
        loadSnapshots()
    }


    // MARK: Apple IPSW catalog

    func loadCatalog() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.catalogURL)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            var found: [String: RestoreImage] = [:]
            Self.collectVirtualMacImages(plist, insideVirtualMac: false, into: &found)
            images = found.values.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
            selected = images.first
            if guest == .macOS { status = isInstalled ? "VM installed. Press Start." : "Choose a macOS IPSW from Apple, then Download & Install." }
        } catch {
            status = "Could not load Apple's IPSW list: \(error.localizedDescription)"
        }
    }

    private static func collectVirtualMacImages(_ node: Any, insideVirtualMac: Bool, into found: inout [String: RestoreImage]) {
        if let dict = node as? [String: Any] {
            if insideVirtualMac,
               let urlString = dict["FirmwareURL"] as? String, let url = URL(string: urlString),
               let version = dict["ProductVersion"] as? String, let build = dict["BuildVersion"] as? String {
                found[urlString] = RestoreImage(version: version, build: build, url: url)
            }
            for (key, value) in dict {
                collectVirtualMacImages(value, insideVirtualMac: insideVirtualMac || key.hasPrefix("VirtualMac"), into: &found)
            }
        } else if let array = node as? [Any] {
            array.forEach { collectVirtualMacImages($0, insideVirtualMac: insideVirtualMac, into: &found) }
        }
    }

    // MARK: Download & install

    func downloadAndInstall() async {
        guard let image = selected else { return }
        busy = true
        defer { busy = false; progress = nil }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: ipswURL.path) {
                status = "Downloading \(image.title)…"
                let temp = try await download(image.url)
                try FileManager.default.moveItem(at: temp, to: ipswURL)
            }
            try await install()
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    private func download(_ url: URL) async throws -> URL {
        progress = 0
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        return try await withCheckedThrowingContinuation { continuation in
            downloadContinuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        MainActor.assumeIsolated { progress = fraction }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this method returns, so move it first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipsw")
        let result = Result { try FileManager.default.moveItem(at: location, to: kept); return kept }
        MainActor.assumeIsolated {
            downloadContinuation?.resume(with: result)
            downloadContinuation = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            downloadContinuation?.resume(throwing: error)
            downloadContinuation = nil
        }
    }

    private func install() async throws {
        status = "Preparing the virtual machine…"
        let restoreImage = try await VZMacOSRestoreImage.image(from: ipswURL)
        guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration,
              requirements.hardwareModel.isSupported else {
            throw NSError(domain: "Macaroon", code: 1, userInfo: [NSLocalizedDescriptionKey: "This IPSW is not supported on this Mac."])
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = requirements.hardwareModel
        platform.machineIdentifier = VZMacMachineIdentifier()
        platform.auxiliaryStorage = try VZMacAuxiliaryStorage(creatingStorageAt: auxURL, hardwareModel: requirements.hardwareModel, options: [.allowOverwrite])
        try requirements.hardwareModel.dataRepresentation.write(to: modelURL)

        if !FileManager.default.fileExists(atPath: diskURL.path) {
            FileManager.default.createFile(atPath: diskURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: diskURL)
            try handle.truncate(atOffset: 64 * 1024 * 1024 * 1024) // 64 GB sparse disk
            try handle.close()
        }

        let config = try makeConfiguration(platform: platform,
                                           cpus: max(requirements.minimumSupportedCPUCount, 4),
                                           memory: max(requirements.minimumSupportedMemorySize, 4 * 1024 * 1024 * 1024))
        let vm = VZVirtualMachine(configuration: config)
        machine = vm
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswURL)
        status = "Installing macOS…"
        progress = 0
        installObservation = installer.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async { self?.progress = p.fractionCompleted }
        }
        try await installer.install()
        installObservation = nil
        try platform.machineIdentifier.dataRepresentation.write(to: machineIDURL)
        machine = nil
        status = "macOS installed. Press Start."
    }

    // MARK: Linux / Windows ARM (EFI boot from an ISO)

    /// Creates an EFI VM (NVRAM, machine ID, 64 GB disk) for the selected guest and boots it from the ISO.
    func installFromISO(_ iso: URL) async {
        do {
            if !isInstalled {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                _ = try VZEFIVariableStore(creatingVariableStoreAt: nvramURL, options: [.allowOverwrite])
                if !FileManager.default.fileExists(atPath: diskURL.path) {
                    FileManager.default.createFile(atPath: diskURL.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: diskURL)
                    try handle.truncate(atOffset: 64 * 1024 * 1024 * 1024) // 64 GB sparse disk
                    try handle.close()
                }
                try VZGenericMachineIdentifier().dataRepresentation.write(to: machineIDURL)
            }
            try iso.path.write(to: isoPathURL, atomically: true, encoding: .utf8)
            objectWillChange.send()
        } catch {
            status = "Failed: \(error.localizedDescription)"
            return
        }
        await start()
    }

    func ejectISO() {
        try? FileManager.default.removeItem(at: isoPathURL)
        objectWillChange.send()
        status = "Installer ISO ejected. The VM boots from its disk next Start."
    }

    private func makeEFIConfiguration() throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        let platform = VZGenericPlatformConfiguration()
        guard let id = VZGenericMachineIdentifier(dataRepresentation: try Data(contentsOf: machineIDURL)) else {
            throw NSError(domain: "Macaroon", code: 2, userInfo: [NSLocalizedDescriptionKey: "VM files are damaged. Delete the VM and reinstall."])
        }
        platform.machineIdentifier = id
        config.platform = platform
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = VZEFIVariableStore(url: nvramURL)
        config.bootLoader = bootLoader
        config.cpuCount = min(4, ProcessInfo.processInfo.processorCount)
        config.memorySize = 4 * 1024 * 1024 * 1024

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]
        config.graphicsDevices = [graphics]

        // NVMe rather than virtio-blk: Windows ARM has an inbox NVMe driver but none for virtio. Linux handles both.
        var storage: [VZStorageDeviceConfiguration] = [
            VZNVMExpressControllerDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false))
        ]
        if let iso = installerISO {
            storage.append(VZUSBMassStorageDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: iso, readOnly: true)))
        }
        config.storageDevices = storage
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        try addCommonDevices(to: config)
        try config.validate()
        return config
    }

    // MARK: Run

    private func makeConfiguration(platform: VZMacPlatformConfiguration, cpus: Int, memory: UInt64) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.platform = platform
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = min(cpus, ProcessInfo.processInfo.processorCount)
        config.memorySize = memory

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)]
        config.graphicsDevices = [graphics]

        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false))]
        config.keyboards = [VZMacKeyboardConfiguration()]
        config.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        try addCommonDevices(to: config)
        try config.validate()
        return config
    }

    /// Network, entropy and the shared folder — the same for every guest.
    private func addCommonDevices(to config: VZVirtualMachineConfiguration) throws {
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        // A new random MAC on every launch makes saved running state un-restorable ("invalid argument"), so keep one.
        if let saved = try? String(contentsOf: macURL, encoding: .utf8), let mac = VZMACAddress(string: saved) {
            network.macAddress = mac
        } else {
            try network.macAddress.string.write(to: macURL, atomically: true, encoding: .utf8)
        }
        config.networkDevices = [network]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Apps dropped on the window land here; macOS guests auto-mount it at /Volumes/My Shared Files,
        // Linux guests can mount it with: mount -t virtiofs com.apple.virtio-fs.automount /mnt
        let share = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: sharedURL, readOnly: false))
        config.directorySharingDevices = [share]
    }

    private func makeMachine() throws -> VZVirtualMachine {
        let config: VZVirtualMachineConfiguration
        if guest == .macOS {
            let platform = VZMacPlatformConfiguration()
            guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: modelURL)),
                  let id = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: machineIDURL)) else {
                throw NSError(domain: "Macaroon", code: 2, userInfo: [NSLocalizedDescriptionKey: "VM files are damaged. Delete the VM and reinstall."])
            }
            platform.hardwareModel = model
            platform.machineIdentifier = id
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxURL)
            config = try makeConfiguration(platform: platform, cpus: 4, memory: 4 * 1024 * 1024 * 1024)
        } else {
            config = try makeEFIConfiguration()
        }
        let vm = VZVirtualMachine(configuration: config)
        vm.delegate = self
        return vm
    }

    func start() async {
        do {
            let vm = try makeMachine()
            machine = vm
            try await vm.start()
            running = true
            switch guest {
            case .macOS: status = "Running. Drag an app onto the window; in the VM open /Volumes/My Shared Files."
            case .linux: status = installerISO != nil ? "Booting the installer ISO. After installing, Stop and Eject ISO." : "Running. Shared folder: mount -t virtiofs com.apple.virtio-fs.automount /mnt"
            case .windows: status = installerISO != nil ? "Booting the installer ISO. After installing, Stop and Eject ISO." : "Running."
            }
        } catch {
            machine = nil
            status = "Start failed: \(error.localizedDescription)"
        }
    }



    func stop() async {
        guard let machine, machine.canStop else { return }
        try? await machine.stop()
        guestStopped()
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { guestStopped() }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated {
            guestStopped()
            status = "VM stopped: \(error.localizedDescription)"
        }
    }

    private func guestStopped() {
        machine = nil
        running = false
        status = "VM stopped."
    }

    // MARK: Snapshots (APFS clones of the disk + aux storage, plus saved running state)

    private var vmFiles: [String] { ["Disk.img", guest == .macOS ? "AuxiliaryStorage" : "NVRAM"] }
    private let stateFile = "State.vzvmsave"

    func loadSnapshots() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: snapshotsURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        snapshots = urls.map(Snapshot.init).sorted { $0.name > $1.name }
    }

    /// On APFS, copyItem makes a copy-on-write clone: instant, and no extra space until blocks change.
    private func clone(_ names: [String], from source: URL, to destination: URL) throws {
        for name in names {
            let target = destination.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: target)
        }
    }

    @discardableResult
    func takeSnapshot(label: String = "Snapshot") async -> Bool {
        busy = true
        defer { busy = false; loadSnapshots() }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = snapshotsURL.appendingPathComponent("\(formatter.string(from: Date())) \(label)")
        var note = ""
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let machine, running {
                status = "Pausing VM for snapshot…"
                try await machine.pause()
                do {
                    try await machine.saveMachineStateTo(url: folder.appendingPathComponent(stateFile))
                } catch {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(stateFile))
                    note = " Disk only; running state not saved: \(error.localizedDescription)"
                }
                try clone(vmFiles, from: root, to: folder)
                try await machine.resume()
            } else {
                try clone(vmFiles, from: root, to: folder)
            }
            status = "Saved snapshot \(folder.lastPathComponent).\(note)"
            return true
        } catch {
            if let machine, machine.state == .paused { try? await machine.resume() }
            try? FileManager.default.removeItem(at: folder)
            status = "Snapshot failed: \(error.localizedDescription)"
            return false
        }
    }

    func restore(_ snapshot: Snapshot) async {
        // Keep the current state so you can always go back to it.
        guard await takeSnapshot(label: "Before Restore") else { return }
        busy = true
        defer { busy = false }
        do {
            if let machine, machine.canStop { try await machine.stop() }
            machine = nil
            running = false
            try clone(vmFiles, from: snapshot.url, to: root)
            guard snapshot.hasState else {
                status = "Restored disk from \(snapshot.name). Press Start."
                return
            }
            status = "Restoring running state from \(snapshot.name)…"
            let vm = try makeMachine()
            machine = vm
            do {
                try await vm.restoreMachineStateFrom(url: snapshot.url.appendingPathComponent(stateFile))
            } catch {
                // The disk is already restored; only the running state can't be used.
                machine = nil
                status = "Restored disk from \(snapshot.name); running state could not be restored (\(error.localizedDescription)). Press Start."
                return
            }
            try await vm.resume()
            running = true
            status = "Restored \(snapshot.name)."
        } catch {
            machine = nil
            running = false
            status = "Restore failed: \(error.localizedDescription)"
        }
    }

    func delete(_ snapshot: Snapshot) {
        do {
            try FileManager.default.removeItem(at: snapshot.url)
            status = "Deleted snapshot \(snapshot.name)."
        } catch {
            status = "Delete failed: \(error.localizedDescription)"
        }
        loadSnapshots()
    }

    // MARK: Drag an app in

    func copyIntoVM(_ app: URL) {
        let destination = sharedURL.appendingPathComponent(app.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: app, to: destination)
            status = "Copied \(app.lastPathComponent) — in the VM: /Volumes/My Shared Files/\(app.lastPathComponent)"
        } catch {
            status = "Copy failed: \(error.localizedDescription)"
        }
    }
}

struct VMView: NSViewRepresentable {
    let machine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        view.virtualMachine = machine
    }
}

struct ContentView: View {
    @ObservedObject var vm: MacaroonVM
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Guest", selection: $vm.guest) {
                    ForEach(GuestOS.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(vm.busy || vm.running)
                if vm.guest == .macOS {
                    Picker("IPSW", selection: $vm.selected) {
                        ForEach(vm.images) { Text($0.title).tag(Optional($0)) }
                    }
                    .frame(maxWidth: 320)
                    .disabled(vm.busy || vm.running)
                    Button("Download & Install") { Task { await vm.downloadAndInstall() } }
                        .disabled(vm.busy || vm.running || vm.selected == nil)
                } else {
                    Button(vm.isInstalled ? "Attach ISO…" : "Install from ISO…") { chooseISO() }
                        .disabled(vm.busy || vm.running)
                    if let iso = vm.installerISO {
                        Button("Eject \(iso.lastPathComponent)") { vm.ejectISO() }
                            .disabled(vm.busy || vm.running)
                    }
                }
                Spacer()
                Button("Start") { Task { await vm.start() } }
                    .disabled(vm.busy || vm.running || !vm.isInstalled)
                Button("Stop") { Task { await vm.stop() } }
                    .disabled(!vm.running)
                Menu("Snapshots") {
                    Button("Take Snapshot") { Task { await vm.takeSnapshot() } }
                    if !vm.snapshots.isEmpty { Divider() }
                    ForEach(vm.snapshots) { snapshot in
                        Menu(snapshot.hasState ? "\(snapshot.name) (running state)" : snapshot.name) {
                            Button("Restore") { Task { await vm.restore(snapshot) } }
                            Button("Delete", role: .destructive) { vm.delete(snapshot) }
                        }
                    }
                }
                .fixedSize()
                .disabled(vm.busy || !vm.isInstalled)
                Button("Shared Folder") { NSWorkspace.shared.open(vm.sharedURL) }
            }
            .padding(10)

            ZStack {
                if let machine = vm.machine, vm.running {
                    VMView(machine: machine)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "desktopcomputer").font(.system(size: 64))
                        Text(vm.isInstalled ? "Press Start to boot the VM." : vm.guest == .macOS
                             ? "Pick an IPSW and press Download & Install."
                             : "Press Install from ISO… and choose an ARM64 (aarch64) \(vm.guest.title) ISO.")
                        Text("Drag an .app here to copy it into the VM.").foregroundStyle(.secondary)
                    }
                }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 4).padding(8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.85))
            .foregroundStyle(.white)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in vm.copyIntoVM(url) }
                    }
                }
                return true
            }

            HStack {
                Text(vm.status).lineLimit(2)
                Spacer()
                if let p = vm.progress { ProgressView(value: p).frame(width: 220) }
            }
            .padding(10)
        }
    }

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage, .diskImage]
        panel.message = "Choose an ARM64 \(vm.guest.title) installer ISO"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await vm.installFromISO(url) }
    }
}
