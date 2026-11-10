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

@MainActor
final class MacaroonVM: NSObject, ObservableObject, VZVirtualMachineDelegate, URLSessionDownloadDelegate {
    @Published var images: [RestoreImage] = []
    @Published var selected: RestoreImage?
    @Published var status = "Loading Apple's IPSW list…"
    @Published var progress: Double?
    @Published var busy = false
    @Published var machine: VZVirtualMachine?
    @Published var running = false

    static let catalogURL = URL(string: "https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml")!
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Macaroon/VM")
    var diskURL: URL { root.appendingPathComponent("Disk.img") }
    var auxURL: URL { root.appendingPathComponent("AuxiliaryStorage") }
    var modelURL: URL { root.appendingPathComponent("HardwareModel") }
    var machineIDURL: URL { root.appendingPathComponent("MachineIdentifier") }
    var ipswURL: URL { root.appendingPathComponent("Restore.ipsw") }
    var sharedURL: URL { root.appendingPathComponent("Shared") }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: machineIDURL.path) }

    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var installObservation: NSKeyValueObservation?

    override init() {
        super.init()
        try? FileManager.default.createDirectory(at: sharedURL, withIntermediateDirectories: true)
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
            status = isInstalled ? "VM installed. Press Start." : "Choose a macOS IPSW from Apple, then Download & Install."
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
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]
        config.keyboards = [VZMacKeyboardConfiguration()]
        config.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Apps dropped on the window land here; macOS guests auto-mount it at /Volumes/My Shared Files.
        let share = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: sharedURL, readOnly: false))
        config.directorySharingDevices = [share]

        try config.validate()
        return config
    }

    func start() async {
        do {
            let platform = VZMacPlatformConfiguration()
            guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: modelURL)),
                  let id = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: machineIDURL)) else {
                throw NSError(domain: "Macaroon", code: 2, userInfo: [NSLocalizedDescriptionKey: "VM files are damaged. Delete the VM and reinstall."])
            }
            platform.hardwareModel = model
            platform.machineIdentifier = id
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxURL)
            let vm = VZVirtualMachine(configuration: try makeConfiguration(platform: platform, cpus: 4, memory: 4 * 1024 * 1024 * 1024))
            vm.delegate = self
            machine = vm
            try await vm.start()
            running = true
            status = "Running. Drag an app onto the window; in the VM open /Volumes/My Shared Files."
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
                Picker("IPSW", selection: $vm.selected) {
                    ForEach(vm.images) { Text($0.title).tag(Optional($0)) }
                }
                .frame(maxWidth: 320)
                .disabled(vm.busy || vm.running)
                Button("Download & Install") { Task { await vm.downloadAndInstall() } }
                    .disabled(vm.busy || vm.running || vm.selected == nil)
                Spacer()
                Button("Start") { Task { await vm.start() } }
                    .disabled(vm.busy || vm.running || !vm.isInstalled)
                Button("Stop") { Task { await vm.stop() } }
                    .disabled(!vm.running)
                Button("Shared Folder") { NSWorkspace.shared.open(vm.sharedURL) }
            }
            .padding(10)

            ZStack {
                if let machine = vm.machine, vm.running {
                    VMView(machine: machine)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "desktopcomputer").font(.system(size: 64))
                        Text(vm.isInstalled ? "Press Start to boot the VM." : "Pick an IPSW and press Download & Install.")
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
}
