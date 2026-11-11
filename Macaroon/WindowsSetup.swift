import CryptoKit
import Foundation

/// Unattended Windows 11 ARM install on Virtualization.framework.
///
/// A Windows ISO can't boot as is (El Torito only, no partition table), Apple's firmware gives Windows no
/// framebuffer, and Windows Setup can't find an answer file on the VM's USB disk. So the ISO is repacked into
/// Media.img, a GPT disk with:
///  - a FAT32 partition typed as EFI system partition: the ISO minus install.wim, with our loader as
///    BOOTAA64.EFI (Tools/WindowsEFI) and boot.wim edited so WinPE runs pe.cmd instead of Setup;
///  - an exFAT partition: install.wim, the virtio-win drivers and the scripts in \macaroon.
/// pe.cmd partitions the NVMe disk, applies install.wim with DISM, adds the drivers, runs bcdboot and powers
/// off. The VM is then started from its disk until SetupComplete.cmd leaves EFI\Macaroon\installed on the ESP.
/// Needs Homebrew's wimlib (`brew install wimlib`) to edit boot.wim.
enum WindowsSetup {
    static let username = NSUserName()
    static let password = "macaroon"

    static let virtioWinURL = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso")!
    static let winFspURL = URL(string: "https://github.com/winfsp/winfsp/releases/download/v2.1/winfsp-2.1.25156.msi")!
    static let winFspSHA256 = "073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a"
    /// virtio-win folders copied for w11/ARM64. Storage is NVMe (inbox driver), so no viostor.
    static let drivers = ["viogpudo", "NetKVM", "viorng", "viofs", "viosock"]

    static var wimlib: String? {
        ["/opt/homebrew/bin/wimlib-imagex", "/usr/local/bin/wimlib-imagex"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func fail(_ message: String) -> NSError {
        NSError(domain: "Macaroon", code: 10, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: Building the media

    static func createMedia(at media: URL, iso: URL, virtioWin: URL, winFsp: URL, progress: @escaping (String) -> Void) throws {
        guard let wimlib else { throw fail("Windows install needs wimlib to edit boot.wim. Run: brew install wimlib") }
        let fm = FileManager.default

        progress("Reading the Windows ISO…")
        let isoRoot = try attachISO(iso)
        defer { detach(isoRoot.path) }
        let installWIM = ["install.wim", "install.esd"].map { isoRoot.appendingPathComponent("sources/\($0)") }.first { fm.fileExists(atPath: $0.path) }
        guard let installWIM, fm.fileExists(atPath: isoRoot.appendingPathComponent("efi/boot/bootaa64.efi").path) else {
            throw fail("\(iso.lastPathComponent) is not a Windows 11 ARM64 installation ISO.")
        }
        let (index, language) = try pickImage(wimlib: wimlib, wim: installWIM)

        progress("Creating the installation disk…")
        let mib: UInt64 = 1024 * 1024
        let wimSize = UInt64((try installWIM.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let size = (200 + 1700 + 1200) * mib + (wimSize + mib - 1) / mib * mib
        try? fm.removeItem(at: media)
        fm.createFile(atPath: media.path, contents: nil)
        let handle = try FileHandle(forWritingTo: media)
        try handle.truncate(atOffset: size)
        try handle.close()

        do {
            let disk = try run("/usr/bin/hdiutil", ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", media.path])
                .split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("/dev/disk") }.map(String.init)
            guard let disk else { throw fail("Could not attach Media.img") }
            defer { detach(disk) }
            // diskutil adds a 200 MB EFI partition first, so these are s2 and s3
            try run("/usr/sbin/diskutil", ["partitionDisk", disk, "GPT", "MS-DOS FAT32", "WINBOOT", "1700m", "ExFAT", "WINSRC", "R"])
            let boot = try mount("\(disk)s2"), source = try mount("\(disk)s3")

            progress("Copying the Windows files…")
            try run("/usr/bin/rsync", ["-rt", "--exclude=sources/install.wim", "--exclude=sources/install.esd", isoRoot.path + "/", boot.path + "/"])
            let wimTarget = source.appendingPathComponent("sources")
            try fm.createDirectory(at: wimTarget, withIntermediateDirectories: true)
            try fm.copyItem(at: installWIM, to: wimTarget.appendingPathComponent(installWIM.lastPathComponent))

            progress("Preparing WinPE…")
            let scratch = fm.temporaryDirectory.appendingPathComponent("macaroon-pe-\(UUID().uuidString)")
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: scratch) }
            try crlf(winpeshl).write(to: scratch.appendingPathComponent("winpeshl.ini"), atomically: true, encoding: .utf8)
            try crlf(peScript).write(to: scratch.appendingPathComponent("pe.cmd"), atomically: true, encoding: .utf8)
            let bootWIM = boot.appendingPathComponent("sources/boot.wim").path
            let bootIndex = try run(wimlib, ["info", bootWIM]).firstMatch(of: #/Boot Index:\s*(\d+)/#).map { String($0.1) } ?? "2"
            try run(wimlib, ["update", bootWIM, bootIndex], input: """
                add '\(scratch.path)/winpeshl.ini' /Windows/System32/winpeshl.ini
                add '\(scratch.path)/pe.cmd' /Windows/System32/pe.cmd

                """)

            // The firmware starts our loader, which starts the framebuffer driver, then Windows Boot Manager
            let efiBoot = boot.appendingPathComponent("efi/boot"), efiMacaroon = boot.appendingPathComponent("efi/Macaroon")
            try fm.moveItem(at: efiBoot.appendingPathComponent("bootaa64.efi"), to: efiBoot.appendingPathComponent("windows.efi"))
            try WindowsEFIBinaries.loader.write(to: efiBoot.appendingPathComponent("bootaa64.efi"))
            try fm.createDirectory(at: efiMacaroon, withIntermediateDirectories: true)
            try WindowsEFIBinaries.framebuffer.write(to: efiMacaroon.appendingPathComponent("framebuffer.efi"))

            let folder = source.appendingPathComponent("macaroon"), driverFolder = folder.appendingPathComponent("drivers")
            try fm.createDirectory(at: driverFolder, withIntermediateDirectories: true)
            try Data("macaroon".utf8).write(to: folder.appendingPathComponent("media.id"))
            try crlf("@echo off\nset IMAGE=/Index:\(index)\n").write(to: folder.appendingPathComponent("config.cmd"), atomically: true, encoding: .utf8)
            try crlf(installScript).write(to: folder.appendingPathComponent("install.cmd"), atomically: true, encoding: .utf8)
            try crlf(setupComplete).write(to: folder.appendingPathComponent("SetupComplete.cmd"), atomically: true, encoding: .utf8)
            try crlf(unattend(language: language)).write(to: folder.appendingPathComponent("unattend.xml"), atomically: true, encoding: .utf8)
            try crlf(agentScript).write(to: folder.appendingPathComponent("agent.ps1"), atomically: true, encoding: .utf8)
            try WindowsEFIBinaries.framebuffer.write(to: folder.appendingPathComponent("framebuffer.efi"))
            try WindowsEFIBinaries.loader.write(to: folder.appendingPathComponent("loader.efi"))
            try fm.copyItem(at: winFsp, to: folder.appendingPathComponent("winfsp.msi"))

            progress("Copying the virtio drivers…")
            let virtio = try attachISO(virtioWin)
            defer { detach(virtio.path) }
            for driver in drivers {
                let from = virtio.appendingPathComponent("\(driver)/w11/ARM64")
                guard fm.fileExists(atPath: from.path) else { throw fail("virtio-win has no \(driver) driver for Windows 11 ARM64.") }
                let to = driverFolder.appendingPathComponent(driver.lowercased())
                try fm.copyItem(at: from, to: to)
                for case let file as URL in fm.enumerator(at: to, includingPropertiesForKeys: nil)! where file.pathExtension.lowercased() == "pdb" {
                    try? fm.removeItem(at: file)
                }
            }
            try fm.copyItem(at: virtio.appendingPathComponent("viofs/w11/ARM64/virtiofs.exe"), to: folder.appendingPathComponent("virtiofs.exe"))

            // macOS writes "._" AppleDouble files on FAT/exFAT, which DISM reads as broken .inf files
            for volume in [boot, source] { _ = try? run("/usr/sbin/dot_clean", ["-m", volume.path]) }
        } catch {
            try? fm.removeItem(at: media)
            throw error
        }
        try retypeAsESP(media, partition: 2)
    }

    /// The edition to install (Pro if there is one) and its language, from `wimlib-imagex info`.
    private static func pickImage(wimlib: String, wim: URL) throws -> (Int, String) {
        let info = try run(wimlib, ["info", wim.path])
        var images: [(index: Int, name: String, language: String)] = []
        for block in info.components(separatedBy: "\nIndex:").dropFirst() {
            let index = Int(block.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)) ?? 0
            let name = block.firstMatch(of: #/\nName:\s*(.+)/#).map { String($0.1) } ?? ""
            let language = block.firstMatch(of: #/\nDefault Language:\s*(\S+)/#).map { String($0.1) } ?? "en-US"
            images.append((index, name, language))
        }
        guard let image = images.first(where: { $0.name == "Windows 11 Pro" }) ?? images.first else {
            throw fail("install.wim has no Windows image.")
        }
        return (image.index, image.language)
    }

    // MARK: Reading results back

    /// install.cmd's result on Media.img: nil if OK, otherwise the end of install.log.
    static func mediaFailure(_ media: URL) -> String? {
        readFile("macaroon/result", fallback: "macaroon/install.log", partition: 3, of: media) { result, log in
            result?.trimmingCharacters(in: .whitespacesAndNewlines) == "OK" ? nil
                : (log ?? "no install.log").split(whereSeparator: \.isNewline).suffix(6).joined(separator: " | ")
        }
    }

    /// Whether SetupComplete.cmd left its marker on the installed system's EFI partition.
    static func firstBootFinished(_ disk: URL) -> Bool {
        readFile("EFI/Macaroon/installed", fallback: nil, partition: 1, of: disk) { marker, _ in marker != nil }
    }

    private static func readFile<T>(_ path: String, fallback: String?, partition: Int, of image: URL, _ body: (String?, String?) -> T) -> T {
        var device: String?
        defer { if let device { detach(device) } }
        if let out = try? run("/usr/bin/hdiutil", ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", "-readonly", image.path]) {
            device = out.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("/dev/disk") }.map(String.init)
        }
        guard let device, let volume = try? mount("\(device)s\(partition)", readOnly: true) else { return body(nil, nil) }
        let read = { (p: String) in try? String(contentsOf: volume.appendingPathComponent(p), encoding: .isoLatin1) }
        return body(read(path), fallback.flatMap(read))
    }

    // MARK: Downloads

    static func winFsp(cache: URL) async throws -> URL {
        let file = cache.appendingPathComponent("winfsp.msi")
        if !FileManager.default.fileExists(atPath: file.path) {
            let (temp, _) = try await URLSession.shared.download(from: winFspURL)
            try FileManager.default.moveItem(at: temp, to: file)
        }
        let hash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard hash == winFspSHA256 else {
            try? FileManager.default.removeItem(at: file)
            throw fail("The WinFsp installer doesn't match its pinned SHA-256.")
        }
        return file
    }

    // MARK: Disk tools

    @discardableResult
    static func run(_ tool: String, _ args: [String], input: String? = nil) throws -> String {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = out
        process.standardError = err
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        // Drain stderr concurrently so neither pipe can fill up and block the tool
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw fail("\((tool as NSString).lastPathComponent) failed: \(String(decoding: errData + outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return String(decoding: outData, as: UTF8.self)
    }

    /// For VMs installed before setup added it: puts virtio-win's VioGpu Resolution Service where the agent installer finds it.
    /// vgpusrv.exe starts viogpuap.exe from its own folder in the user's session, so both are needed.
    static func copyResolutionService(from virtioWin: URL, to folder: URL) throws {
        let names = ["vgpusrv.exe", "viogpuap.exe"]
        guard names.contains(where: { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }) else { return }
        let root = try attachISO(virtioWin)
        defer { detach(root.path) }
        for name in names where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            try FileManager.default.copyItem(at: root.appendingPathComponent("viogpudo/w11/ARM64/\(name)"), to: folder.appendingPathComponent(name))
        }
    }

    private static func attachISO(_ iso: URL) throws -> URL {
        let point = FileManager.default.temporaryDirectory.appendingPathComponent("macaroon-iso-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", point.path, iso.path])
        return point
    }

    private static func detach(_ deviceOrMountPoint: String) {
        _ = try? run("/usr/bin/hdiutil", ["detach", "-force", deviceOrMountPoint])
    }

    private static func mount(_ device: String, readOnly: Bool = false) throws -> URL {
        func mountPoint() -> String? {
            guard let plist = try? run("/usr/sbin/diskutil", ["info", "-plist", device]),
                  let info = try? PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any],
                  let point = info["MountPoint"] as? String, !point.isEmpty else { return nil }
            return point
        }
        if mountPoint() == nil { try run("/usr/sbin/diskutil", readOnly ? ["mount", "readOnly", device] : ["mount", device]) }
        guard let point = mountPoint() else { throw fail("Could not mount \(device)") }
        return URL(fileURLWithPath: point)
    }

    /// diskutil can only make FAT32 "Microsoft Basic Data"; the firmware wants the boot files on an EFI system
    /// partition (and WinPE then hides it). Rewrites the type GUID in both GPT copies and fixes their CRCs.
    private static func retypeAsESP(_ image: URL, partition: Int) throws {
        let handle = try FileHandle(forUpdating: image)
        defer { try? handle.close() }
        func read(_ offset: UInt64, _ count: Int) throws -> Data { try handle.seek(toOffset: offset); return try handle.read(upToCount: count) ?? Data() }
        func write(_ data: Data, _ offset: UInt64) throws { try handle.seek(toOffset: offset); try handle.write(contentsOf: data) }
        func u64(_ d: Data, _ at: Int) -> UInt64 { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt64.self) } }
        func u32(_ d: Data, _ at: Int) -> Int { Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }) }
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        // C12A7328-F81F-11D2-BA4B-00A0C93EC93B in GPT's mixed-endian layout
        let esp = Data([0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B])

        let primary = try read(512, 92)
        guard primary.prefix(8) == Data("EFI PART".utf8) else { throw fail("Media.img has no GPT") }
        for lba in [UInt64(1), u64(primary, 32)] {
            var header = try read(lba * 512, 92)
            let entriesLBA = u64(header, 72), count = u32(header, 80), size = u32(header, 84)
            var entries = try read(entriesLBA * 512, count * size)
            entries.replaceSubrange((partition - 1) * size ..< (partition - 1) * size + 16, with: esp)
            try write(entries, entriesLBA * 512)
            header.replaceSubrange(88..<92, with: le32(crc32(entries)))
            header.replaceSubrange(16..<20, with: Data(count: 4))
            header.replaceSubrange(16..<20, with: le32(crc32(header)))
            try write(header, lba * 512)
        }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    // MARK: Scripts (Windows wants CRLF)

    static func crlf(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: "\r\n") }

    /// WinPE's shell: our script instead of Windows Setup.
    static let winpeshl = """
        [LaunchApps]
        %SYSTEMDRIVE%\\Windows\\System32\\wpeinit.exe
        %SYSTEMDRIVE%\\Windows\\System32\\cmd.exe, /c %SYSTEMDRIVE%\\Windows\\System32\\pe.cmd

        """

    /// Waits for the media's exFAT volume to get a drive letter, loads the display driver, installs, powers off.
    static let peScript = #"""
        @echo off
        set M=
        for /l %%i in (1,1,120) do (
          for %%d in (C D E F G H I J K L M N O P Q R S T U V Y Z) do if exist %%d:\macaroon\media.id set M=%%d:
          if defined M goto found
          ping -n 3 127.0.0.1 >nul
        )
        goto off
        :found
        drvload %M%\macaroon\drivers\viogpudo\viogpudo.inf
        call %M%\macaroon\install.cmd %M%
        :off
        wpeutil shutdown

        """#

    static let installScript = #"""
        @echo off
        setlocal EnableExtensions
        set M=%1
        set T=%M%\macaroon
        set LOG=%T%\install.log
        echo [%time%] start > %LOG%
        call %T%\config.cmd

        rem The target is the only disk with no partitions (the media has three). diskpart output is localized,
        rem so use exit codes: "select partition 1" fails on an empty disk.
        set COUNT=0
        for /l %%d in (0,1,7) do (
          > X:\probe.txt echo select disk %%d
          diskpart /s X:\probe.txt >nul 2>&1 && (
            >> X:\probe.txt echo select partition 1
            diskpart /s X:\probe.txt >nul 2>&1 || (set DISK=%%d& set /a COUNT+=1)
          )
        )
        if not "%COUNT%"=="1" (echo [%time%] expected one empty disk, found %COUNT% >> %LOG% & goto fail)
        echo [%time%] target disk %DISK% >> %LOG%

        (
        echo select disk %DISK%
        echo clean
        echo convert gpt
        echo create partition efi size=260
        echo format quick fs=fat32 label=System
        echo assign letter=S
        echo create partition msr size=16
        echo create partition primary
        echo format quick fs=ntfs label=Windows
        echo assign letter=W
        ) > X:\partition.txt
        diskpart /s X:\partition.txt >> %LOG% 2>&1 || goto fail

        set WIM=%M%\sources\install.wim
        if not exist %WIM% set WIM=%M%\sources\install.esd
        echo [%time%] applying %WIM% %IMAGE% >> %LOG%
        dism /Apply-Image /ImageFile:%WIM% %IMAGE% /ApplyDir:W:\ >> %LOG% 2>&1 || goto fail

        echo [%time%] adding drivers >> %LOG%
        dism /Image:W:\ /Add-Driver /Driver:%T%\drivers /Recurse >> %LOG% 2>&1 || goto fail

        mkdir W:\Windows\Panther W:\Windows\Setup\Scripts W:\ProgramData\Macaroon 2>nul
        copy /y %T%\unattend.xml W:\Windows\Panther\unattend.xml >> %LOG% || goto fail
        copy /y %T%\SetupComplete.cmd W:\Windows\Setup\Scripts\SetupComplete.cmd >> %LOG% || goto fail
        copy /y %T%\winfsp.msi W:\ProgramData\Macaroon\winfsp.msi >> %LOG% || goto fail
        copy /y %T%\virtiofs.exe W:\ProgramData\Macaroon\virtiofs.exe >> %LOG% || goto fail
        copy /y %T%\agent.ps1 W:\ProgramData\Macaroon\agent.ps1 >> %LOG% || goto fail
        copy /y %T%\drivers\viogpudo\vgpusrv.exe W:\ProgramData\Macaroon\vgpusrv.exe >> %LOG% || goto fail
        copy /y %T%\drivers\viogpudo\viogpuap.exe W:\ProgramData\Macaroon\viogpuap.exe >> %LOG% || goto fail

        echo [%time%] boot files >> %LOG%
        bcdboot W:\Windows /s S: /f UEFI >> %LOG% 2>&1 || goto fail
        rem Same chain as the media: loader -> framebuffer driver -> Windows Boot Manager
        mkdir S:\EFI\Macaroon S:\EFI\BOOT 2>nul
        copy /y %T%\framebuffer.efi S:\EFI\Macaroon\framebuffer.efi >> %LOG% || goto fail
        copy /y S:\EFI\Microsoft\Boot\bootmgfw.efi S:\EFI\BOOT\windows.efi >> %LOG% || goto fail
        copy /y %T%\loader.efi S:\EFI\BOOT\BOOTAA64.EFI >> %LOG% || goto fail

        echo [%time%] done >> %LOG%
        echo OK> %T%\result
        exit /b 0
        :fail
        echo [%time%] FAILED >> %LOG%
        echo FAILED> %T%\result
        exit /b 0

        """#

    /// Runs once as SYSTEM at the end of setup: shared folder support, the guest agent (started at every logon,
    /// with automatic logon so it is always there), then a marker for the host, then power off.
    static let setupComplete = #"""
        @echo off
        powercfg /hibernate off
        start /wait "" msiexec /i C:\ProgramData\Macaroon\winfsp.msi /qn /norestart
        sc create VirtioFsSvc binpath= C:\ProgramData\Macaroon\virtiofs.exe start= auto depend= WinFsp.Launcher/VirtioFsDrv DisplayName= "Virtio FS Service"
        rem VioGpu Resolution Service: makes viogpudo follow the size Macaroon's window asks for (in points)
        C:\ProgramData\Macaroon\vgpusrv.exe -i
        reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run /v MacaroonAgent /t REG_SZ /d "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ProgramData\Macaroon\agent.ps1" /f
        set WL="HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        reg add %WL% /v AutoAdminLogon /t REG_SZ /d 1 /f
        reg add %WL% /v DefaultUserName /t REG_SZ /d "\#(username)" /f
        reg add %WL% /v DefaultPassword /t REG_SZ /d "\#(password)" /f
        reg delete %WL% /v AutoLogonCount /f
        mountvol S: /S
        mkdir S:\EFI\Macaroon 2>nul
        echo done> S:\EFI\Macaroon\installed
        mountvol S: /D
        shutdown /s /t 5 /c "Macaroon: Windows setup complete"

        """#

    /// For VMs installed before the agent existed: Macaroon puts this and agent.ps1 in the shared folder; running it
    /// once in Windows installs the agent for the current user (no admin needed) and starts it.
    static let agentInstaller = #"""
        @echo off
        cd /d "%TEMP%"
        set A=%LOCALAPPDATA%\Macaroon
        mkdir "%A%" 2>nul
        copy /y "%~dp0agent.ps1" "%A%\agent.ps1" || (pause & exit /b 1)
        reg add HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v MacaroonAgent /t REG_SZ /d "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%A%\agent.ps1\"" /f
        start "" powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%A%\agent.ps1"
        rem VMs installed before setup added it: the VioGpu Resolution Service (needs admin, so Windows asks once)
        rem makes the display follow Macaroon's window size
        sc query vgpusrv >nul 2>&1 || if exist "%~dp0vgpusrv.exe" (
          mkdir C:\ProgramData\Macaroon 2>nul
          copy /y "%~dp0vgpusrv.exe" C:\ProgramData\Macaroon\vgpusrv.exe
          copy /y "%~dp0viogpuap.exe" C:\ProgramData\Macaroon\viogpuap.exe
          if exist C:\ProgramData\Macaroon\vgpusrv.exe (
            powershell -NoProfile -Command "Start-Process -Verb RunAs -Wait C:\ProgramData\Macaroon\vgpusrv.exe -ArgumentList '-i'"
          )
        )
        rem Undo the forced 200% scaling an earlier installer set (it doubled everything); takes effect at next sign-in
        reg delete "HKCU\Control Panel\Desktop" /v LogPixels /f >nul 2>&1
        reg delete "HKCU\Control Panel\Desktop" /v Win8DpiScaling /f >nul 2>&1
        rem An earlier installer put in a patched, test-signed viogpudo: Windows bugchecks with it (at logon and when
        rem the window is resized). Go back to virtio-win's (admin, so Windows asks once) and restart to load it.
        if exist C:\ProgramData\Macaroon\viogpudo-vz\ if exist "%~dp0viogpudo-remove.ps1" (
          copy /y "%~dp0viogpudo-remove.ps1" C:\ProgramData\Macaroon\viogpudo-remove.ps1
          powershell -NoProfile -Command "exit (Start-Process -Verb RunAs -Wait -PassThru powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\Macaroon\viogpudo-remove.ps1').ExitCode" && (
            echo Restarting Windows to load the standard display driver...
            rem Virtualization.framework stops the VM when Windows restarts; this tells Macaroon to start it again
            echo.> "%~dp0Macaroon restart"
            shutdown /r /t 10 /c "Macaroon: restarting to load the standard display driver"
          )
        )
        echo Macaroon guest agent installed and started.
        timeout /t 3 >nul

        """#

    /// Run as administrator by agentInstaller: removes the patched viogpudo an earlier installer added (its boot task,
    /// driver package, test certificate and test signing) so Windows binds virtio-win's viogpudo again.
    static let gpuDriverRemoval = #"""
        Start-Transcript -Append (Join-Path $env:ProgramData 'Macaroon\viogpudo-vz.log') | Out-Null
        schtasks /delete /f /tn 'Macaroon viogpudo-vz'
        function Patched { Get-WindowsDriver -Online | Where-Object { $_.OriginalFileName -like '*\viogpudo.inf' -and $_.Version -eq '100.6.101.58000' } }
        foreach ($d in Patched) { pnputil /delete-driver $d.Driver /uninstall /force }
        if (Patched) { exit 1 }
        pnputil /scan-devices
        certutil -delstore Root 0fe9d0a10924022ca38a9e469c88acf8d882785a
        certutil -delstore TrustedPublisher 0fe9d0a10924022ca38a9e469c88acf8d882785a
        bcdedit /set '{current}' testsigning off
        Remove-Item -Recurse -Force (Join-Path $env:ProgramData 'Macaroon\viogpudo-vz'), (Join-Path $env:ProgramData 'Macaroon\viogpudo-vz.done') -ErrorAction SilentlyContinue
        exit 0

        """#

    /// Port the guest agent listens on (virtio-vsock, through virtio-win's viosock Winsock provider).
    static let agentPort: UInt32 = 52000

    /// Guest agent, run at logon in the user's session (so it can reach the clipboard). One request per
    /// connection, one line: "exec <command>" streams cmd.exe's output back; "clip-get" returns the clipboard
    /// text; "clip-set <base64 UTF-8>" sets it; "resize <width> <height>" sets the desktop size.
    /// Its log is %TEMP%\macaroon-agent.log.
    static let agentScript = #"""
        Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
        using System;
        using System.Diagnostics;
        using System.Net;
        using System.Net.Sockets;
        using System.Runtime.InteropServices;
        using System.Text;
        using System.Threading;
        using System.Windows.Forms;

        public class VsockEndPoint : EndPoint {
            readonly AddressFamily family; uint cid, port;
            public VsockEndPoint(AddressFamily family, uint cid, uint port) { this.family = family; this.cid = cid; this.port = port; }
            public override AddressFamily AddressFamily { get { return family; } }
            // sockaddr_vm: family, reserved, port, cid
            public override SocketAddress Serialize() {
                var a = new SocketAddress(family, 16);
                for (int i = 0; i < 4; i++) { a[4 + i] = (byte)(port >> (8 * i)); a[8 + i] = (byte)(cid >> (8 * i)); }
                return a;
            }
            public override EndPoint Create(SocketAddress a) {
                uint p = 0, c = 0;
                for (int i = 0; i < 4; i++) { p |= (uint)a[4 + i] << (8 * i); c |= (uint)a[8 + i] << (8 * i); }
                return new VsockEndPoint(family, c, p);
            }
        }

        public static class MacaroonAgent {
            [DllImport("ws2_32.dll", CharSet = CharSet.Unicode)]
            static extern int WSAEnumProtocolsW(IntPtr protocols, IntPtr buffer, ref int length);
            static string logPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "macaroon-agent.log");
            static void Log(string s) { try { System.IO.File.AppendAllText(logPath, DateTime.Now.ToString("s") + " " + s + "\r\n"); } catch { } }

            // viosock registers its own address family; find it by the provider's name
            static AddressFamily VsockFamily() {
                new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp).Close(); // WSAStartup
                int length = 0;
                WSAEnumProtocolsW(IntPtr.Zero, IntPtr.Zero, ref length);
                IntPtr buffer = Marshal.AllocHGlobal(length);
                int count = WSAEnumProtocolsW(IntPtr.Zero, buffer, ref length);
                int family = 40;
                for (int i = 0; i < count; i++) {
                    IntPtr info = new IntPtr(buffer.ToInt64() + i * 628); // sizeof(WSAPROTOCOL_INFOW)
                    int af = Marshal.ReadInt32(info, 76);
                    string name = Marshal.PtrToStringUni(new IntPtr(info.ToInt64() + 116));
                    Log("provider " + af + " " + name);
                    if (name.IndexOf("vsock", StringComparison.OrdinalIgnoreCase) >= 0 || name.IndexOf("virtio", StringComparison.OrdinalIgnoreCase) >= 0) family = af;
                }
                Marshal.FreeHGlobal(buffer);
                return (AddressFamily)family;
            }

            // Retries forever: at logon the viosock Winsock provider (VirtioSocketWSP service) may not be registered yet
            public static void Run(uint port) {
                while (true) {
                    Socket server = null;
                    try {
                        var family = VsockFamily();
                        server = new Socket(family, SocketType.Stream, ProtocolType.Unspecified);
                        server.Bind(new VsockEndPoint(family, 0xFFFFFFFF, port));
                        server.Listen(8);
                        Log("listening on " + (int)family + ":" + port);
                        while (true) {
                            Socket client = server.Accept();
                            new Thread(() => Handle(client)) { IsBackground = true }.Start();
                        }
                    } catch (Exception e) { Log(e.ToString()); }
                    if (server != null) server.Close();
                    Thread.Sleep(5000);
                }
            }

            static void Send(Socket s, string text) {
                byte[] data = Encoding.UTF8.GetBytes(text);
                int sent = 0;
                while (sent < data.Length) sent += s.Send(data, sent, data.Length - sent, SocketFlags.None);
            }

            static void Handle(Socket s) {
                try {
                    var line = new System.IO.MemoryStream();
                    var one = new byte[1];
                    while (s.Receive(one) == 1 && one[0] != 10) line.WriteByte(one[0]);
                    string request = Encoding.UTF8.GetString(line.ToArray()).TrimEnd('\r');
                    if (request.StartsWith("exec ")) Exec(s, request.Substring(5));
                    else if (request.StartsWith("resize ")) {
                        string[] size = request.Substring(7).Split(' ');
                        Send(s, Resize(int.Parse(size[0]), int.Parse(size[1])));
                    }
                    else if (request == "clip-get") Send(s, OnSTA(() => Clipboard.ContainsText() ? Clipboard.GetText() : ""));
                    else if (request.StartsWith("clip-set ")) {
                        string text = Encoding.UTF8.GetString(Convert.FromBase64String(request.Substring(9)));
                        OnSTA(() => { if (text.Length > 0) Clipboard.SetText(text); return ""; });
                    }
                } catch (Exception e) { Log(e.ToString()); }
                try { s.Shutdown(SocketShutdown.Both); } catch { }
                s.Close();
            }

            static void Exec(Socket s, string command) {
                var encoding = Encoding.GetEncoding(System.Globalization.CultureInfo.CurrentCulture.TextInfo.OEMCodePage);
                var info = new ProcessStartInfo("cmd.exe", "/d /c " + command) {
                    UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
                    RedirectStandardOutput = true, RedirectStandardError = true,
                    StandardOutputEncoding = encoding, StandardErrorEncoding = encoding,
                    WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
                };
                var lockObject = new object();
                DataReceivedEventHandler forward = (sender, e) => { if (e.Data != null) lock (lockObject) { try { Send(s, e.Data + "\n"); } catch { } } };
                using (var process = new Process { StartInfo = info }) {
                    process.OutputDataReceived += forward;
                    process.ErrorDataReceived += forward;
                    process.Start();
                    process.StandardInput.Close();
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                    process.WaitForExit();
                    if (process.ExitCode != 0) lock (lockObject) Send(s, "[exit code " + process.ExitCode + "]\n");
                }
            }

            [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
            [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, [Out] int[] path, ref uint modes, [Out] int[] mode, IntPtr topology);
            [DllImport("user32.dll")] static extern int SetDisplayConfig(uint paths, int[] path, uint modes, int[] mode, uint flags);

            // Gives the desktop the size Macaroon just asked viogpudo for. virtio-win's own helper (vgpusrv starts
            // viogpuap.exe for this) never finds the adapter: EnumDisplayDevices returns nothing on recent Windows.
            static string Resize(int width, int height) {
                uint paths, modes;
                int r = GetDisplayConfigBufferSizes(2, out paths, out modes); // QDC_ONLY_ACTIVE_PATHS
                if (r != 0) return "error " + r;
                var path = new int[18 * paths]; // DISPLAYCONFIG_PATH_INFO is 72 bytes, DISPLAYCONFIG_MODE_INFO 64
                var mode = new int[16 * modes];
                r = QueryDisplayConfig(2, ref paths, path, ref modes, mode, IntPtr.Zero);
                if (r != 0) return "error " + r;
                // A source mode (infoType 1) has its width and height right after infoType, id and adapterId
                for (int i = 0; i < modes; i++) if (mode[16 * i] == 1) { mode[16 * i + 4] = width; mode[16 * i + 5] = height; }
                // SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE
                r = SetDisplayConfig(paths, path, modes, mode, 0x80 | 0x20 | 0x400 | 0x200);
                return r == 0 ? "ok" : "error " + r;
            }

            static string OnSTA(Func<string> body) {
                string result = ""; Exception error = null;
                var thread = new Thread(() => { try { result = body(); } catch (Exception e) { error = e; } });
                thread.SetApartmentState(ApartmentState.STA);
                thread.Start();
                thread.Join();
                if (error != null) throw error;
                return result;
            }
        }
        '@
        [MacaroonAgent]::Run(\#(agentPort))

        """#

    /// Local administrator that logs on once, no OOBE screens.
    static func unattend(language: String) -> String {
        let shell = #"name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS""#
        let international = #"name="Microsoft-Windows-International-Core" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS""#
        let user = username.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
            <?xml version="1.0" encoding="utf-8"?>
            <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <settings pass="specialize">
                <component \(shell)>
                  <ComputerName>MACAROON-WIN</ComputerName>
                  <TimeZone>UTC</TimeZone>
                </component>
              </settings>
              <settings pass="oobeSystem">
                <component \(international)>
                  <InputLocale>\(language)</InputLocale>
                  <SystemLocale>\(language)</SystemLocale>
                  <UILanguage>\(language)</UILanguage>
                  <UserLocale>\(language)</UserLocale>
                </component>
                <component \(shell)>
                  <OOBE>
                    <HideEULAPage>true</HideEULAPage>
                    <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                    <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                    <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                    <HideLocalAccountScreen>true</HideLocalAccountScreen>
                    <ProtectYourPC>3</ProtectYourPC>
                    <SkipMachineOOBE>true</SkipMachineOOBE>
                    <SkipUserOOBE>true</SkipUserOOBE>
                  </OOBE>
                  <UserAccounts>
                    <LocalAccounts>
                      <LocalAccount wcm:action="add">
                        <Name>\(user)</Name>
                        <Group>Administrators</Group>
                        <Password><Value>\(password)</Value><PlainText>true</PlainText></Password>
                      </LocalAccount>
                    </LocalAccounts>
                  </UserAccounts>
                  <AutoLogon>
                    <Enabled>true</Enabled>
                    <LogonCount>1</LogonCount>
                    <Username>\(user)</Username>
                    <Password><Value>\(password)</Value><PlainText>true</PlainText></Password>
                  </AutoLogon>
                </component>
              </settings>
            </unattend>

            """
    }
}
