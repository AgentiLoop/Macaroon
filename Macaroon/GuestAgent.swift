import AppKit
import Virtualization

/// Host side of the Windows guest agent (WindowsSetup.agentScript): one request per vsock connection.
@MainActor
enum GuestAgent {
    /// Sends one request line and returns everything the agent writes back before it closes the connection.
    static func request(_ machine: VZVirtualMachine, _ line: String) async throws -> String {
        guard let device = machine.socketDevices.first as? VZVirtioSocketDevice else {
            throw WindowsSetup.fail("This VM has no virtio socket device.")
        }
        let connection = try await device.connect(toPort: WindowsSetup.agentPort)
        defer { connection.close() }
        let fd = connection.fileDescriptor
        let data = try await Task.detached {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.write(contentsOf: Data((line + "\n").utf8))
            return try handle.readToEnd() ?? Data()
        }.value
        return String(decoding: data, as: UTF8.self)
    }

    static func exec(_ machine: VZVirtualMachine, _ command: String) async throws -> String {
        try await request(machine, "exec " + command)
    }

    /// Turns off Windows' display timeout, sleep and screen saver (VMs installed before setup did), retrying
    /// until the agent answers. Gives up after about five minutes.
    static func keepScreenOn(_ machine: VZVirtualMachine) async {
        let command = #"powercfg /change monitor-timeout-ac 0 & powercfg /change monitor-timeout-dc 0 & powercfg /change standby-timeout-ac 0 & powercfg /change standby-timeout-dc 0 & reg add "HKCU\Control Panel\Desktop" /v ScreenSaveActive /t REG_SZ /d 0 /f"#
        for _ in 0..<60 {
            if (try? await exec(machine, command)) != nil { return }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Keeps the Mac and Windows clipboards in sync (text only) until cancelled. Polls once a second
    /// Keeps the Mac and Windows clipboards in sync (text only) until cancelled. Polls once a second.
    static func syncClipboard(_ machine: VZVirtualMachine) async {
        let pasteboard = NSPasteboard.general
        var macChange = pasteboard.changeCount
        var lastGuest: String?
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if pasteboard.changeCount != macChange {
                macChange = pasteboard.changeCount
                if let text = pasteboard.string(forType: .string),
                   (try? await request(machine, "clip-set " + Data(text.utf8).base64EncodedString())) != nil {
                    lastGuest = text
                }
            }
            if let text = try? await request(machine, "clip-get"), !text.isEmpty, text != lastGuest {
                lastGuest = text
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                macChange = pasteboard.changeCount
            }
        }
    }
}
