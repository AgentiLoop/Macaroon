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
                .task { await vm.loadCatalog(); await vm.loadISOCatalog() }
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

/// A Linux or Windows ARM installer ISO. Ubuntu has a direct URL; Windows has a Microsoft SKU whose link is requested at download time.
struct InstallerISO: Identifiable, Hashable {
    let title: String
    let fileName: String
    var url: URL? = nil
    var sku: String? = nil
    var id: String { title }
}

struct Snapshot: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var hasState: Bool { FileManager.default.fileExists(atPath: url.appendingPathComponent("State.vzvmsave").path) }
}

/// macOS guests use Apple's Mac platform; Linux and Windows ARM boot from an ISO through the generic EFI platform.
/// MacCube is a second macOS VM pinned to macOS 27.2.1, given a NeXTSTEP look by a setup script in the shared folder.
enum GuestOS: String, CaseIterable, Identifiable {
    case macOS, linux, windows, macCube
    var id: String { rawValue }
    var title: String {
        switch self {
        case .macOS: "macOS"
        case .linux: "Linux"
        case .windows: "Windows ARM"
        case .macCube: "MacCube"
        }
    }
    var folder: String {
        switch self {
        case .macOS: "VM"
        case .linux: "Linux"
        case .windows: "Windows"
        case .macCube: "MacCube"
        }
    }
    /// Runs on Apple's Mac platform (IPSW install, VZMacOSBootLoader).
    var isMac: Bool { self == .macOS || self == .macCube }
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
                : guest == .macCube ? "Download & Install macOS \(Self.macCubeVersion) for MacCube."
                : "Choose an ARM64 \(guest.title) installer ISO."
            // Show the cached list for the new guest right away; fetch only if it was never loaded
            showISOs()
            if guest == .linux || guest == .windows, isoCache[guest] == nil { Task { await loadISOCatalog(guest) } }
            pickIPSW()
        }
    }
    /// The IPSW menu: every Virtual Mac IPSW for macOS, only the pinned release for MacCube.
    static let macCubeVersion = "27.2.1"
    /// Run once inside MacCube: NeXTSTEP-style Dock on the right edge with big fixed tiles, dark graphite
    /// appearance, solid NeXT grey desktop, high contrast borders and no transparency. Best effort: settings
    /// macOS protects (accessibility) are skipped with a note instead of failing.
    static let nextLookScript = #"""
    #!/bin/zsh
    # MacCube: give macOS a NeXTSTEP look. Safe to run again.
    echo "Setting up the NeXT look…"
    # The macOS Dock: along the bottom, auto-hidden (point at the bottom edge to show it; Option-Command-D turns
    # hiding on and off), 64-pt tiles, no magnification. NeXT Workspace's tile Dock stays on the right.
    defaults write com.apple.dock orientation -string bottom
    defaults write com.apple.dock tilesize -int 64
    defaults write com.apple.dock magnification -bool false
    defaults write com.apple.dock autohide -bool true
    defaults delete com.apple.dock autohide-delay 2>/dev/null
    defaults write com.apple.dock show-recents -bool false
    defaults write com.apple.dock mineffect -string scale
    # Dark grey, graphite accent and highlight, like NeXTSTEP's monochrome look
    defaults write -g AppleInterfaceStyle -string Dark
    defaults write -g AppleAccentColor -int -1
    defaults write -g AppleHighlightColor -string "0.847059 0.847059 0.862745 Graphite"
    defaults write -g AppleReduceDesktopTinting -bool true
    defaults write -g NSTableViewDefaultSizeMode -int 1
    # Square, bordered, opaque windows (needs Privacy & Security > Full Disk Access for Terminal on some releases)
    defaults write com.apple.universalaccess reduceTransparency -bool true 2>/dev/null || echo "Skipped: Reduce Transparency (turn it on in System Settings > Accessibility > Display)"
    defaults write com.apple.universalaccess increaseContrast -bool true 2>/dev/null || echo "Skipped: Increase Contrast (turn it on in System Settings > Accessibility > Display)"
    # Solid NeXT grey desktop (#555555)
    wall="$HOME/Pictures/NeXT Grey.png"
    mkdir -p "$HOME/Pictures"
    echo "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAD0lEQVR4nGMIxQEYhpYEAOkwP8EcYhReAAAAAElFTkSuQmCC" | base64 -D > "$wall"
    osascript -e "tell application \"System Events\" to set picture of every desktop to POSIX file \"$wall\"" \
        || echo "Skipped: desktop picture (allow Terminal to control System Events, then run again)"
    # Finder as NeXTSTEP's File Viewer: the column browser (NeXT invented it), path shown above and in the title,
    # every window opening on the home folder, full file names
    defaults write com.apple.finder FXPreferredViewStyle -string clmv
    defaults write com.apple.finder ShowPathbar -bool true
    defaults write com.apple.finder ShowStatusBar -bool true
    defaults write com.apple.finder _FXShowPosixPathInTitle -bool true
    defaults write com.apple.finder NewWindowTarget -string PfHm
    defaults write com.apple.finder NewWindowTargetPath -string "file://$HOME/"
    defaults write com.apple.finder FXDefaultSearchScope -string SCcf
    defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false
    defaults write -g AppleShowAllExtensions -bool true
    # The Workspace desktop: no icons on it, just the grey background and the Dock
    defaults write com.apple.finder CreateDesktop -bool false
    # NeXT had no permanent menu bar across the top; show it only when the pointer reaches the top edge
    defaults write -g _HIHideMenuBar -bool true
    # Home folder as a Dock tile, like NeXT's file viewer tile (added once)
    defaults read com.apple.dock persistent-others 2>/dev/null | grep -q "file://$HOME/\"" || defaults write com.apple.dock persistent-others -array-add \
        "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>file://$HOME/</string><key>_CFURLStringType</key><integer>15</integer></dict><key>file-label</key><string>Home</string><key>displayas</key><integer>1</integer><key>showas</key><integer>2</integer><key>arrangement</key><integer>1</integer></dict><key>tile-type</key><string>directory-tile</string></dict>"
    # NeXT Workspace (Tools/MacCube): NeXTSTEP's tile Dock on the right and its vertical main menu at the top
    # left, started at every login. It replaces the macOS Dock, which is pushed out of the way.
    src="/Volumes/My Shared Files/NeXT Workspace.app"
    # Copies an app from the shared folder without quarantine or other attributes, then re-signs it here (ad hoc,
    # same identifier requirement). A quarantined ad-hoc app is what macOS reports as "damaged".
    install_app() {
        # A bundle caught mid-build on the Mac (no Info.plist or executable) would show the circle-slash icon
        if [ ! -f "$1/Contents/Info.plist" ] || [ -z "$(ls "$1/Contents/MacOS" 2>/dev/null)" ]; then
            echo "Skipped ${2:t}: incomplete in the Shared Folder (rebuild with Tools/MacCube/build.sh, then run this again)"
            return
        fi
        rm -rf "$2"
        ditto --noextattr --noqtn "$1" "$2"
        xattr -cr "$2"
        codesign -s - -f -r="designated => identifier \"$3\"" "$2" >/dev/null 2>&1 || echo "Could not sign $2"
        # Fresh icon in Finder and the Dock (they cache icons by path)
        touch "$2"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$2" 2>/dev/null
        echo "Installed ${2:t} (build $(defaults read "$2/Contents/Info" CFBundleVersion 2>/dev/null))"
        [ -f "$2/Contents/Resources/Assets.car" ] || echo "  WARNING: ${2:t} has no icon (no Assets.car in $1); rebuild with Tools/MacCube/build.sh"
    }
    if [ -d "$src" ]; then
        mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
        install_app "$src" "$HOME/Applications/NeXT Workspace.app" com.macaroon.NeXTWorkspace
        # NeXT apps replace their macOS counterparts in the Dock (also in a Dock saved by an earlier run)
        for pair in "NeXT Calculator:/System/Applications/Calculator.app" "NeXT Browser:/Applications/Safari.app" "NeXT Edit:/System/Applications/TextEdit.app" "NeXT Terminal:/System/Applications/Utilities/Terminal.app" "NeXT Apps:/System/Applications/Apps.app"; do
            name=${pair%%:*} old=${pair#*:}
            [ -d "/Volumes/My Shared Files/$name.app" ] || continue
            install_app "/Volumes/My Shared Files/$name.app" "$HOME/Applications/$name.app" "com.macaroon.${name// /}"
            dock=$(defaults read com.macaroon.NeXTWorkspace DockApps 2>/dev/null | grep -o '"[^"]*"' | tr -d '"')
            if [ -n "$dock" ]; then
                defaults write com.macaroon.NeXTWorkspace DockApps -array ${(f)"$(print -r -- "$dock" | sed "s|^$old$|$HOME/Applications/$name.app|")"}
            fi
        done
        # NeXT Apps belongs in the NeXT Dock even when a saved Dock never had Apple's Apps: add it after the Finder
        apps="$HOME/Applications/NeXT Apps.app"
        dock=$(defaults read com.macaroon.NeXTWorkspace DockApps 2>/dev/null | grep -o '"[^"]*"' | tr -d '"')
        if [ -d "$apps" ] && [ -n "$dock" ] && ! print -r -- "$dock" | grep -qxF "$apps"; then
            tiles=(${(f)dock})
            defaults write com.macaroon.NeXTWorkspace DockApps -array "$tiles[1]" "$apps" "${(@)tiles[2,-1]}"
        fi
        agent="$HOME/Library/LaunchAgents/com.macaroon.NeXTWorkspace.plist"
        cat > "$agent" <<EOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
        <key>Label</key><string>com.macaroon.NeXTWorkspace</string>
        <key>ProgramArguments</key><array><string>$HOME/Applications/NeXT Workspace.app/Contents/MacOS/NeXTWorkspace</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    </dict></plist>
    EOF
        launchctl bootout gui/$(id -u) "$agent" 2>/dev/null
        # An older build's Accessibility entry no longer matches this signature; clear it so the switch is real
        tccutil reset Accessibility com.macaroon.NeXTWorkspace 2>/dev/null
        launchctl bootstrap gui/$(id -u) "$agent"
        echo "NeXT Workspace installed. Allow it in System Settings > Privacy & Security > Accessibility so its menu can show each app's menus."
    else
        echo "Skipped: NeXT Workspace.app is not in the Shared Folder (build it on the Mac with Tools/MacCube/build.sh)"
    fi
    # Icon Services caches app icons by bundle id and version; restart it so replaced apps show their new icons
    killall iconservicesagent 2>/dev/null
    killall Dock SystemUIServer Finder 2>/dev/null
    echo "Done. Log out and back in for the dark appearance to reach every app."
    """#
    var ipswChoices: [RestoreImage] { guest == .macCube ? images.filter { $0.version == Self.macCubeVersion } : images }
    private func pickIPSW() {
        if let selected, ipswChoices.contains(selected) { return }
        selected = ipswChoices.first
    }
    @Published var isos: [InstallerISO] = []
    @Published var selectedISO: InstallerISO? {
        didSet { if let selectedISO { isoChoice[guest] = selectedISO } }
    }
    /// ISO lists and the user's pick per guest, so switching guests doesn't blank the ISO menu.
    private var isoCache: [GuestOS: [InstallerISO]] = [:]
    private var isoChoice: [GuestOS: InstallerISO] = [:]

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
            pickIPSW()
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
        if guest == .windows { return await installWindows(from: iso) }
        do {
            if !isInstalled {
                try createEFIMachine()
            }
            try iso.path.write(to: isoPathURL, atomically: true, encoding: .utf8)
            objectWillChange.send()
        } catch {
            status = "Failed: \(error.localizedDescription)"
            return
        }
        await start()
    }

    private func createEFIMachine() throws {
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

    // MARK: Windows unattended install (see WindowsSetup)

    var mediaURL: URL { root.appendingPathComponent("Media.img") }
    /// "media" while WinPE installs from Media.img, "firstboot" while Windows sets itself up; absent otherwise.
    var setupPhaseURL: URL { root.appendingPathComponent("WindowsSetup") }
    private var setupPhase: String? { try? String(contentsOf: setupPhaseURL, encoding: .utf8) }

    /// Repacks the ISO into Media.img, then boots a fresh VM from it. The VM powers off and restarts by itself
    /// a few times; `guestDidStop` drives the rest.
    func installWindows(from iso: URL) async {
        busy = true
        defer { busy = false; progress = nil }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let virtioWin = base.appendingPathComponent("virtio-win.iso")
            if !FileManager.default.fileExists(atPath: virtioWin.path) {
                status = "Downloading the virtio-win drivers…"
                try FileManager.default.moveItem(at: try await download(WindowsSetup.virtioWinURL), to: virtioWin)
                progress = nil
            }
            status = "Downloading WinFsp…"
            let winFsp = try await WindowsSetup.winFsp(cache: base)
            let media = mediaURL
            // Test-signed viogpudo build (viogpudo.inf/.sys/.cat + VirtIOTestCert.cer) used instead of virtio-win's: a local
            // rebuild in Application Support if there is one, otherwise the one shipped in the app (Payload/viogpudo-test)
            var testDriver = base.appendingPathComponent("viogpudo-test")
            if !FileManager.default.fileExists(atPath: testDriver.appendingPathComponent("viogpudo.inf").path),
               let bundled = Bundle.main.resourceURL?.appendingPathComponent("Payload/viogpudo-test") {
                testDriver = bundled
            }
            try await Task.detached {
                try WindowsSetup.createMedia(at: media, iso: iso, virtioWin: virtioWin, winFsp: winFsp, testDriver: testDriver) { step in
                    Task { @MainActor in self.status = step }
                }
            }.value
            // Fresh disk and NVRAM: install.cmd installs onto the one empty disk
            try? FileManager.default.removeItem(at: diskURL)
            try createEFIMachine()
            try media.path.write(to: isoPathURL, atomically: true, encoding: .utf8)
            try "media".write(to: setupPhaseURL, atomically: true, encoding: .utf8)
            objectWillChange.send()
        } catch {
            status = "Failed: \(error.localizedDescription)"
            return
        }
        await start()
    }

    /// Called whenever the guest powers off or reboots during setup.
    private func continueWindowsSetup() async {
        switch setupPhase {
        case "media":
            status = "Checking the install result…"
            if let failure = await (Task.detached { [mediaURL] in WindowsSetup.mediaFailure(mediaURL) }).value {
                try? FileManager.default.removeItem(at: setupPhaseURL)
                status = "Windows install failed (Media.img kept): \(failure)"
                return
            }
            try? FileManager.default.removeItem(at: isoPathURL)
            try? "firstboot".write(to: setupPhaseURL, atomically: true, encoding: .utf8)
            objectWillChange.send()
        case "firstboot":
            if await (Task.detached { [diskURL] in WindowsSetup.firstBootFinished(diskURL) }).value {
                try? FileManager.default.removeItem(at: setupPhaseURL)
                try? FileManager.default.removeItem(at: mediaURL)
                await start()
                status = "Windows installed. User \(WindowsSetup.username), password \(WindowsSetup.password)."
                return
            }
        default:
            return
        }
        await start()
        status = "Windows is setting itself up; it restarts a few times on its own…"
    }


    func ejectISO() {
        try? FileManager.default.removeItem(at: isoPathURL)
        objectWillChange.send()
        status = "Installer ISO ejected. The VM boots from its disk next Start."
    }

    // MARK: ISO catalogs (Ubuntu from cdimage.ubuntu.com, Windows 11 ARM from Microsoft)

    static let ubuntuReleases = URL(string: "https://cdimage.ubuntu.com/ubuntu/releases/")!
    static let windowsPage = URL(string: "https://www.microsoft.com/en-us/software-download/windows11arm64")!
    static let msProfile = "606624d44113"
    /// Microsoft serves one link request per session, so each download gets a fresh, handshaken session.
    private var msSession = UUID().uuidString.lowercased()
    private var msEdition: String?

    /// Loads the Linux and Windows ISO lists together at launch, so switching guests later is instant.
    func loadISOCatalog() async {
        async let linux: Void = loadISOCatalog(.linux)
        async let windows: Void = loadISOCatalog(.windows)
        _ = await (linux, windows)
    }

    private func loadISOCatalog(_ wanted: GuestOS) async {
        guard wanted == .linux || wanted == .windows else { return }
        do {
            let found: [InstallerISO]
            switch wanted {
            case .linux: found = try await ubuntuISOs()
            default: found = try await windowsISOs()
            }
            isoCache[wanted] = found
            guard guest == wanted else { return }
            showISOs()
            if !isInstalled { status = "Choose a \(wanted == .linux ? "Ubuntu" : "Windows 11 ARM") ISO, then Download & Install." }
        } catch {
            guard guest == wanted else { return }
            status = "Could not load the \(wanted.title) ISO list: \(error.localizedDescription)"
        }
    }

    /// Puts the current guest's cached ISO list (and its last pick) into the menu in one update.
    private func showISOs() {
        let found = isoCache[guest] ?? []
        let pick = isoChoice[guest].flatMap { found.contains($0) ? $0 : nil }
            ?? (guest == .windows ? found.first { $0.title.hasSuffix("– English") } : nil) ?? found.first
        isos = found
        selectedISO = pick
    }

    /// The newest point release of each Ubuntu release (22.04 and later), desktop and server, arm64.
    private func ubuntuISOs() async throws -> [InstallerISO] {
        let (index, _) = try await URLSession.shared.data(from: Self.ubuntuReleases)
        let html = String(decoding: index, as: UTF8.self)
        let found: [String] = html.matches(of: try Regex(#"href="(\d+\.\d+)/""#)).compactMap { match in
            match.output[1].substring.map { String($0) }
        }
        let versions: [String] = Set(found)
            .filter { $0.compare("22.04", options: .numeric) != .orderedAscending }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        var result: [InstallerISO] = []
        for version in versions {
            let folder = Self.ubuntuReleases.appendingPathComponent("\(version)/release/")
            guard let (sums, _) = try? await URLSession.shared.data(from: folder.appendingPathComponent("SHA256SUMS")) else { continue }
            let names = String(decoding: sums, as: UTF8.self).matches(of: try Regex(#"ubuntu-[\d.]+-(?:desktop|live-server)-arm64\.iso"#)).map { String($0.output[0].substring ?? "") }
            for (flavor, label) in [("-desktop-", "Desktop"), ("-live-server-", "Server")] {
                guard let name = names.filter({ $0.contains(flavor) }).max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else { continue }
                let number = name.dropFirst("ubuntu-".count).prefix { $0.isNumber || $0 == "." }
                result.append(InstallerISO(title: "Ubuntu \(number) \(label) (arm64)", fileName: name, url: folder.appendingPathComponent(name)))
            }
        }
        return result
    }


    private func msRequest(_ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://www.microsoft.com/software-download-connector/api/\(path)&Locale=en-US&sessionID=\(msSession)")!)
        request.setValue(Self.windowsPage.absoluteString, forHTTPHeaderField: "Referer")
        return request
    }

    /// One entry per language of Microsoft's Windows 11 ARM64 multi-edition ISO.
    private func windowsISOs() async throws -> [InstallerISO] {
        let (page, _) = try await URLSession.shared.data(from: Self.windowsPage)
        guard let edition = String(decoding: page, as: UTF8.self).firstMatch(of: try Regex(#"option value="(\d+)""#))?.output[1].substring else {
            throw NSError(domain: "Macaroon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Microsoft's download page has no ARM64 edition."])
        }
        msEdition = String(edition)
        return try await windowsSKUs(edition: String(edition)).compactMap { sku in
            guard let id = sku["Id"] as? String, let language = sku["Language"] as? String else { return nil }
            let product = (sku["ProductDisplayName"] as? String) ?? "Windows 11 ARM64"
            return InstallerISO(title: "\(product) – \(language)", fileName: "Windows11-ARM64-\(language).iso", sku: id)
        }
    }

    /// Starts a fresh Microsoft session the way Fido (github.com/pbatard/Fido) does: whitelist it through vlscppe,
    /// pass the ov-df "Sentinel" anti-bot check (mdt.js gives w and rticks, then reply), then list the edition's SKUs.
    private func windowsSKUs(edition: String) async throws -> [[String: Any]] {
        let instance = "560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175"
        msSession = UUID().uuidString.lowercased()
        _ = try? await URLSession.shared.data(from: URL(string: "https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=\(msSession)")!)
        let (script, _) = try await URLSession.shared.data(from: URL(string: "https://ov-df.microsoft.com/mdt.js?instanceId=\(instance)&PageId=si&session_id=\(msSession)")!)
        let js = String(decoding: script, as: UTF8.self)
        if let w = js.firstMatch(of: try Regex(#"[?&]w=([A-F0-9]+)"#))?.output[1].substring,
           let rticks = js.firstMatch(of: try Regex(#"rticks="\+?(\d+)"#))?.output[1].substring {
            let now = Int(Date().timeIntervalSince1970 * 1000)
            _ = try? await URLSession.shared.data(from: URL(string: "https://ov-df.microsoft.com/?session_id=\(msSession)&CustomerId=\(instance)&PageId=si&w=\(w)&mdt=\(now)&rticks=\(rticks)")!)
        }
        let (data, _) = try await URLSession.shared.data(for: msRequest("getskuinformationbyproductedition?profile=\(Self.msProfile)&ProductEditionId=\(edition)&SKU=undefined&friendlyFileName=undefined"))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["Skus"] as? [[String: Any]] ?? []
    }

    /// Direct ISO link for a SKU, on a new handshaken session (Microsoft processes one request per session).
    /// Nil only if Microsoft still refuses; then the browser is the fallback.
    private func windowsDownloadURL(sku: String) async -> URL? {
        if let edition = msEdition { _ = try? await windowsSKUs(edition: edition) }
        guard let (data, _) = try? await URLSession.shared.data(for: msRequest("GetProductDownloadLinksBySku?profile=\(Self.msProfile)&productEditionId=undefined&SKU=\(sku)&friendlyFileName=undefined")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let options = json["ProductDownloadOptions"] as? [[String: Any]],
              let uri = options.compactMap({ $0["Uri"] as? String }).first else { return nil }
        return URL(string: uri)
    }

    /// The newest finished Windows ARM64 ISO in ~/Downloads (Safari/Chrome only rename it to .iso once complete).
    /// Fuzzy: Microsoft names it e.g. Win11_25H2_English_Arm64.iso or Windows11_Client_arm64_en-us_26300_9457.iso.
    private var downloadedWindowsISO: URL? {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: keys)) ?? []
        let candidates = files.filter { url in
            let name = url.lastPathComponent.lowercased()
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return name.hasSuffix(".iso") && name.contains("win")
                && ["arm64", "aarch64", "arm"].contains { name.contains($0) }
                && size > 1_000_000_000
        }
        func date(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return candidates.max { date($0) < date($1) }
    }


    func downloadAndInstallISO() async {
        guard let iso = selectedISO else { return }
        let wanted = guest
        busy = true
        defer { busy = false; progress = nil }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var file = root.appendingPathComponent(iso.fileName)
            if !FileManager.default.fileExists(atPath: file.path) {
                if wanted == .windows, let local = downloadedWindowsISO {
                    file = local
                } else if let url = iso.url {
                    status = "Downloading \(iso.title)…"
                    let downloaded = try await download(url)
                    try? FileManager.default.removeItem(at: file) // a copy may have appeared while downloading
                    try FileManager.default.moveItem(at: downloaded, to: file)
                } else if let sku = iso.sku, let url = await windowsDownloadURL(sku: sku) {
                    status = "Downloading \(iso.title)…"
                    let downloaded = try await download(url)
                    try? FileManager.default.removeItem(at: file) // a copy may have appeared while downloading
                    try FileManager.default.moveItem(at: downloaded, to: file)
                } else {
                    // Microsoft blocked the direct link: download in the browser and pick it up from ~/Downloads.
                    NSWorkspace.shared.open(Self.windowsPage)
                    status = "Microsoft requires its web page: choose the language, click Download (64-bit ARM). Waiting for a Windows ARM64 .iso in Downloads…"
                    while guest == wanted, downloadedWindowsISO == nil { try await Task.sleep(for: .seconds(3)) }
                    guard let local = downloadedWindowsISO else { return }
                    file = local
                }
            }
            guard guest == wanted else { return }
            await installFromISO(file)
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    private func makeEFIConfiguration() throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        let platform = VZGenericPlatformConfiguration()
        guard let id = VZGenericMachineIdentifier(dataRepresentation: try Data(contentsOf: machineIDURL)) else {
            throw NSError(domain: "Macaroon", code: 2, userInfo: [NSLocalizedDescriptionKey: "VM files are damaged. Delete the VM and reinstall."])
        }
        platform.machineIdentifier = id
        // Windows spins one vCPU at 100% forever without a PMU. Private, undocumented switch (as used by tart's Windows branch).
        let pmu = NSSelectorFromString("_setPerformanceMonitoringUnitEmulationEnabled:")
        if guest == .windows, platform.responds(to: pmu) {
            platform.setValue(true, forKey: "performanceMonitoringUnitEmulationEnabled")
        }
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
            storage.append(VZUSBMassStorageDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: iso, readOnly: iso.pathExtension.lowercased() == "iso")))
        }
        config.storageDevices = storage
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        try addCommonDevices(to: config)
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()] // Windows guest agent, Linux GPU OpenGL (LinuxGL)
        if guest == .linux {
            // Clipboard sharing through the SPICE agent port; Ubuntu Desktop's spice-vdagent picks it up
            let spice = VZSpiceAgentPortAttachment()
            spice.sharesClipboard = true
            let port = VZVirtioConsolePortConfiguration()
            port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
            port.attachment = spice
            let console = VZVirtioConsoleDeviceConfiguration()
            console.ports[0] = port
            config.consoleDevices = [console]
        }
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

        // Sound, as VirtualBuddy does: one virtio sound device with the host's speakers as output and its
        // microphone as input (macOS asks for microphone permission the first time a guest records)
        let sound = VZVirtioSoundDeviceConfiguration()
        let speaker = VZVirtioSoundDeviceOutputStreamConfiguration()
        speaker.sink = VZHostAudioOutputStreamSink()
        let microphone = VZVirtioSoundDeviceInputStreamConfiguration()
        microphone.source = VZHostAudioInputStreamSource()
        sound.streams = [speaker, microphone]
        config.audioDevices = [sound]

        // Apps dropped on the window land here; macOS guests auto-mount it at /Volumes/My Shared Files,
        // Linux guests can mount it with: mount -t virtiofs com.apple.virtio-fs.automount /mnt
        let share = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: sharedURL, readOnly: false))
        config.directorySharingDevices = [share]
    }

    private func makeMachine() throws -> VZVirtualMachine {
        let config: VZVirtualMachineConfiguration
        if guest.isMac {
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

    /// `recovery`: macOS guests boot into macOS Recovery (Utilities → Terminal → csrutil disable to turn SIP off).
    func start(recovery: Bool = false) async {
        do {
            let vm = try makeMachine()
            machine = vm
            if recovery, guest.isMac {
                let options = VZMacOSVirtualMachineStartOptions()
                options.startUpFromMacOSRecovery = true
                try await vm.start(options: options)
                running = true
                status = "Recovery: choose Options, sign in, then Utilities → Terminal → csrutil disable, then reboot."
                return
            }
            try await vm.start()
            running = true
            switch guest {
            case .macOS: status = "Running. Drag an app onto the window; in the VM open /Volumes/My Shared Files."
            case .linux:
                status = installerISO != nil ? "Booting the installer ISO. After installing, Stop and Eject ISO." : "Running. Shared folder: mount -t virtiofs com.apple.virtio-fs.automount /mnt"
                linuxGL = LinuxGL(machine: vm)
                if linuxGL != nil { // the installed system can boot with the ISO still attached, so don't wait for an eject
                    try? LinuxGL.guestSetupScript.write(to: sharedURL.appendingPathComponent("Set Up 3D.sh"), atomically: true, encoding: .utf8)
                    status += ". GPU OpenGL: run sudo sh \"/mnt/Set Up 3D.sh\" once, then macaroon-gl <app>"
                }
            case .macCube:
                let script = sharedURL.appendingPathComponent("Set Up NeXT Look.command")
                try? Self.nextLookScript.write(to: script, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
                status = "Running MacCube. For the NeXT look, double-click Set Up NeXT Look.command in /Volumes/My Shared Files."
            case .windows:
                status = setupPhase == "media" ? "Installing Windows from Media.img (WinPE, unattended). The VM powers off when done." : "Running."
                if setupPhase == nil {
                    // Lets VMs installed before the guest agent existed install (or update) it from the shared folder
                    try? WindowsSetup.crlf(WindowsSetup.agentScript).write(to: sharedURL.appendingPathComponent("agent.ps1"), atomically: true, encoding: .utf8)
                    try? WindowsSetup.crlf(WindowsSetup.agentInstaller).write(to: sharedURL.appendingPathComponent("Install Macaroon Agent.cmd"), atomically: true, encoding: .utf8)
                    try? WindowsSetup.copyResolutionService(from: base.appendingPathComponent("virtio-win.iso"), to: sharedURL)
                    clipboardTask = Task { await GuestAgent.syncClipboard(vm) }
                    Task { await GuestAgent.keepScreenOn(vm) }
                }
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
        MainActor.assumeIsolated {
            // Not the machine Stop just shut down (stop() already cleared it)
            let guestInitiated = virtualMachine === machine
            guestStopped()
            // Virtualization.framework stops the VM when the guest reboots (it has no reset), so restart it.
            // Windows can't tell a restart from a shutdown here; use Stop to power it off.
            guard guest == .windows, guestInitiated else { return }
            if setupPhase != nil { Task { await continueWindowsSetup() }; return }
            Task {
                await start()
                if running { status = "Windows restarted. Use Stop to power it off." }
            }
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated {
            guestStopped()
            status = "VM stopped: \(error.localizedDescription)"
        }
    }

    private var clipboardTask: Task<Void, Never>?
    private var linuxGL: LinuxGL?

    /// Runs a cmd.exe command line in the Windows guest through the guest agent and returns its output.
    func runInWindows(_ command: String) async -> String {
        guard let machine, running else { return "The VM is not running." }
        do {
            return try await GuestAgent.exec(machine, command)
        } catch {
            return "The guest agent didn't answer (\(error.localizedDescription)). It starts when Windows logs on; wait for the desktop and try again."
        }
    }


    /// Types the Mac clipboard's text into the guest as key presses (US layout), for guests without clipboard sharing.
    func typeClipboard() {
        guard running, let view = VMView.Coordinator.current else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            status = "The Mac clipboard has no text to paste."
            return
        }
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
        GuestKeyboard.type(text, in: view)
        status = "Typed \(text.count) characters from the Mac clipboard (US layout; other characters are skipped)."
    }

    private func guestStopped() {
        clipboardTask?.cancel()
        clipboardTask = nil
        linuxGL?.stop()
        linuxGL = nil
        machine = nil
        running = false
        status = "VM stopped."
    }

    // MARK: Snapshots (APFS clones of the disk + aux storage, plus saved running state)

    private var vmFiles: [String] { ["Disk.img", guest.isMac ? "AuxiliaryStorage" : "NVRAM"] }
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

/// Sends keystrokes to the guest through the VM view (US layout), for when no guest agent is running.
@MainActor
enum GuestKeyboard {
    private static let unshifted = Array("asdfhgzxcv\u{0}bqweryt123465=97-80]ou[ip\u{0}lj'k;\\,/nm.\u{0}\u{0}`")
    private static let shifted = Array("ASDFHGZXCV\u{0}BQWERYT!@#$^%+(&_*)}OU{IP\u{0}LJ\"K:|<?NM>\u{0}\u{0}~")

    static func type(_ text: String, in view: NSView) {
        for ch in text {
            if ch == " " { press(49, in: view); continue }
            if ch == "\n" || ch == "\r\n" || ch == "\r" { press(36, in: view); continue }
            if ch == "\t" { press(48, in: view); continue }
            if let i = unshifted.firstIndex(of: ch) {
                press(UInt16(i), in: view)
            } else if let i = shifted.firstIndex(of: ch) {
                press(UInt16(i), in: view, modifier: (56, .shift))
            }
        }
    }

    static func press(_ keyCode: UInt16, in view: NSView, modifier: (UInt16, NSEvent.ModifierFlags)? = nil) {
        func event(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                             isARepeat: false, keyCode: code)!
        }
        let flags = modifier?.1 ?? []
        if let (code, f) = modifier { view.flagsChanged(with: event(.flagsChanged, code, f)) }
        view.keyDown(with: event(.keyDown, keyCode, flags))
        view.keyUp(with: event(.keyUp, keyCode, flags))
        if let (code, _) = modifier { view.flagsChanged(with: event(.flagsChanged, code, [])) }
    }
}

struct VMView: NSViewRepresentable {
    let machine: VZVirtualMachine
    /// macOS guests get the window's full Retina pixel size. Windows/Linux get its size in points: asking them for
    /// Retina pixels only works with 200% scaling in the guest, which doubles everything when the driver doesn't follow.
    var retina = true
    var resizesGuest = true
    /// Windows: after resizing the display, ask the guest agent to switch the desktop to the new mode
    var windowsAgent = false

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = retina
        context.coordinator.view = view
        context.coordinator.retina = retina
        context.coordinator.resizesGuest = resizesGuest
        context.coordinator.windowsAgent = windowsAgent
        Coordinator.current = view
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        view.virtualMachine = machine
        context.coordinator.attach(machine.graphicsDevices.first?.displays.first)
    }

    static func dismantleNSView(_ view: VZVirtualMachineView, coordinator: Coordinator) {
        coordinator.attach(nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The guest may not take the exact size asked for (Windows' driver picks the nearest mode it has),
    /// which leaves the picture letterboxed. Once the guest settles, reshape the window to its aspect ratio.
    final class Coordinator: NSObject, VZGraphicsDisplayObserver {
        weak var view: VZVirtualMachineView?
        static weak var current: VZVirtualMachineView?
        var retina = true
        var resizesGuest = true
        var windowsAgent = false
        private var display: VZGraphicsDisplay?
        private var resizeObservers: [NSObjectProtocol] = []
        private var pending: DispatchWorkItem?

        func attach(_ newDisplay: VZGraphicsDisplay?) {
            guard newDisplay !== display else { return }
            display?.removeObserver(self)
            display = newDisplay
            display?.addObserver(self)
            resizeObservers.forEach(NotificationCenter.default.removeObserver)
            resizeObservers = []
            guard newDisplay != nil else { return }
            for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didResizeNotification] {
                resizeObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let self, let window = self.view?.window, (note.object as? NSWindow) === window, !window.inLiveResize else { return }
                    self.settle()
                })
            }
            DispatchQueue.main.async { self.settle() }
        }

        /// Ask the guest for the view's size (points, when not Retina), then give it a moment to apply it before fitting.
        /// Windows needs the PR #1717 viogpudo (stock virtio-win unrefs the resource still on the scanout, so mode
        /// changes scramble or blank the picture) plus the guest agent to switch the desktop to the new mode.
        private func settle() {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if !self.retina, self.resizesGuest, let display = self.display, let size = self.view?.bounds.size, size.width > 0, size.height > 0 {
                    // Multiples of 8: viogpudo scrambles the picture (wrong row stride) for other widths
                    let width = max(640, Int(size.width) / 8 * 8), height = max(480, Int(size.height) / 8 * 8)
                    try? display.reconfigure(sizeInPixels: CGSize(width: width, height: height))
                    // Windows: viogpudo now offers that size as a mode; the guest agent switches the desktop to it
                    if self.windowsAgent, let machine = self.view?.virtualMachine {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1))
                            _ = try? await GuestAgent.request(machine, "resize \(width) \(height)")
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.fit() }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        func displayDidReconfigure(_ display: VZGraphicsDisplay) {
            DispatchQueue.main.async { self.fit() }
        }

        private func fit() {
            guard let size = display?.sizeInPixels, size.width > 0, size.height > 0,
                  let view, let window = view.window, !window.inLiveResize,
                  !window.styleMask.contains(.fullScreen) else { return }
            let bounds = view.bounds.size
            let aspect = size.width / size.height
            guard bounds.height > 0, abs(bounds.width / bounds.height - aspect) > 0.01 else { return }
            var frame = window.frame
            let height = (bounds.width / aspect).rounded()
            if let screen = window.screen?.visibleFrame, frame.height + height - bounds.height > screen.height {
                // Too tall for the screen: keep the height and narrow the window instead.
                let width = (bounds.height * aspect).rounded()
                frame.origin.x += (bounds.width - width) / 2
                frame.size.width += width - bounds.width
            } else {
                frame.origin.y -= height - bounds.height
                frame.size.height += height - bounds.height
            }
            window.setFrame(frame, display: true, animate: true)
        }
    }
}

struct ContentView: View {
    @ObservedObject var vm: MacaroonVM
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Guest", selection: $vm.guest) {
                    ForEach(GuestOS.allCases) { Text($0 == .macOS ? "Mac" : $0 == .windows ? "Windows" : $0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(vm.busy || vm.running)
                if vm.guest.isMac {
                    Picker("IPSW", selection: $vm.selected) {
                        ForEach(vm.ipswChoices) { Text($0.title).tag(Optional($0)) }
                    }
                    .frame(maxWidth: 320)
                    .disabled(vm.busy || vm.running)
                    Button("Download & Install") { Task { await vm.downloadAndInstall() } }
                        .disabled(vm.busy || vm.running || vm.selected == nil)
                } else {
                    Picker("ISO", selection: $vm.selectedISO) {
                        if vm.isos.isEmpty { Text("Loading…").tag(InstallerISO?.none) }
                        ForEach(vm.isos) { Text($0.title).tag(Optional($0)) }
                    }
                    .frame(maxWidth: 320)
                    .disabled(vm.busy || vm.running)
                    Button("Download & Install") { Task { await vm.downloadAndInstallISO() } }
                        .disabled(vm.busy || vm.running || vm.selectedISO == nil)
                    Button(vm.isInstalled && vm.guest != .windows ? "Attach ISO…" : "Install from ISO…") { chooseISO() }
                        .disabled(vm.busy || vm.running)
                    if let iso = vm.installerISO {
                        Button("Eject \(iso.lastPathComponent)") { vm.ejectISO() }
                            .disabled(vm.busy || vm.running)
                    }
                }
                Spacer()
                Button("Start") { Task { await vm.start() } }
                    .disabled(vm.busy || vm.running || !vm.isInstalled)
                if vm.guest.isMac {
                    Button("Start in Recovery") { Task { await vm.start(recovery: true) } }
                        .disabled(vm.busy || vm.running || !vm.isInstalled)
                }
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
                if vm.guest == .windows {
                    Button("Run Command…") { runCommand() }
                        .disabled(!vm.running)
                }
                if vm.guest == .linux {
                    Button("Paste") { vm.typeClipboard() }
                        .help("Types the Mac clipboard's text into Linux")
                        .disabled(!vm.running)
                }
            }
            .padding(10)

            ZStack {
                if let machine = vm.machine, vm.running {
                    VMView(machine: machine, retina: vm.guest.isMac, windowsAgent: vm.guest == .windows)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "desktopcomputer").font(.system(size: 64))
                        Text(vm.isInstalled ? "Press Start to boot the VM." : vm.guest.isMac
                             ? "Pick an IPSW and press Download & Install."
                             : "Pick an ISO and press Download & Install, or use Install from ISO… with your own ARM64 ISO.")
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

    /// Asks for a cmd.exe command line, runs it in Windows, shows its output.
    private func runCommand() {
        let alert = NSAlert()
        alert.messageText = "Run in Windows"
        alert.informativeText = "A cmd.exe command line, e.g. ver or winget install Git.Git"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        let command = field.stringValue
        vm.status = "Running \(command) in Windows…"
        Task {
            let output = await vm.runInWindows(command)
            vm.status = "Ran \(command) in Windows."
            let result = NSAlert()
            result.messageText = command
            let outputURL = vm.base.appendingPathComponent("LastCommandOutput.txt")
            do {
                try "Command: \(command)\n\n\(output)".write(to: outputURL, atomically: true, encoding: .utf8)
                result.informativeText = "Output saved to \(outputURL.path)"
            } catch {
                result.informativeText = "Could not save output: \(error.localizedDescription)"
            }
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
            let text = scroll.documentView as! NSTextView
            text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.string = output.isEmpty ? "(no output)" : output
            result.accessoryView = scroll
            result.runModal()
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
