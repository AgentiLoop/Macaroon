import Foundation
import Virtualization

/// GPU-accelerated OpenGL for Linux guests. Virtualization.framework's virtio-gpu is 2D only, so the guest's
/// Mesa uses its virpipe driver, which sends GL commands over a vsock to virgl_test_server (built by
/// Tools/VirGL/build.sh). That runs them on the Mac's GPU through CGL and sends the finished frames back.
@MainActor
final class LinuxGL: NSObject, VZVirtioSocketListenerDelegate {
    static let port: UInt32 = 30311
    static let serverURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Macaroon/VirGL/virgl_test_server")

    private let server = Process()
    private let socketPath = NSTemporaryDirectory() + "macaroon-virgl-\(getpid()).sock"
    private let listener = VZVirtioSocketListener()
    private weak var device: VZVirtioSocketDevice?

    /// Starts the renderer and listens for the guest. Nil when the server isn't built or the VM has no vsock.
    init?(machine: VZVirtualMachine) {
        guard FileManager.default.isExecutableFile(atPath: Self.serverURL.path),
              let device = machine.socketDevices.first as? VZVirtioSocketDevice else { return nil }
        super.init()
        unlink(socketPath)
        server.executableURL = Self.serverURL
        // No fork per client: Metal (under Apple's OpenGL) can't build pipelines in a forked child, so every draw came out
        // black. Clients are then served one at a time (--multi-clients needs vtest protocol 3, which virpipe over vsock lacks).
        server.arguments = ["--no-fork", "--socket-path", socketPath]
        let log = Self.serverURL.deletingLastPathComponent().appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        server.standardOutput = try? FileHandle(forWritingTo: log)
        server.standardError = server.standardOutput
        do { try server.run() } catch { return nil }
        listener.delegate = self
        device.setSocketListener(listener, forPort: Self.port)
        self.device = device
    }

    func stop() {
        device?.removeSocketListener(forPort: Self.port)
        if server.isRunning { server.terminate() }
        unlink(socketPath)
    }

    nonisolated func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                              from socketDevice: VZVirtioSocketDevice) -> Bool {
        let path = MainActor.assumeIsolated { socketPath }
        let host = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8.prefix(buffer.count - 1))
            buffer.copyBytes(from: bytes)
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(host, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard host >= 0, connected == 0 else {
            if host >= 0 { close(host) }
            return false
        }
        // One thread per direction; the connection (and its fd) stays alive until both are done
        let guest = connection.fileDescriptor
        let group = DispatchGroup()
        for (from, to) in [(guest, host), (host, guest)] {
            group.enter()
            Thread {
                Self.pump(from, to)
                shutdown(to, SHUT_WR)
                group.leave()
            }.start()
        }
        group.notify(queue: .global()) {
            close(host)
            connection.close()
        }
        return true
    }

    private nonisolated static func pump(_ from: Int32, _ to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = read(from, &buffer, buffer.count)
            if count <= 0 { return }
            var sent = 0
            while sent < count {
                let n = buffer.withUnsafeBytes { write(to, $0.baseAddress! + sent, count - sent) }
                if n <= 0 { return }
                sent += n
            }
        }
    }

    /// Run once in Ubuntu (sudo sh) to install the guest half: a socat bridge from Mesa's vtest socket to
    /// the vsock port, and `macaroon-gl`, which runs a program with its OpenGL on the Mac's GPU.
    static let guestSetupScript = """
    #!/bin/sh
    # Macaroon: OpenGL on the Mac's GPU for Ubuntu. Run once:  sudo sh "/mnt/Set Up 3D.sh"
    # (after: sudo mount -t virtiofs com.apple.virtio-fs.automount /mnt)
    set -e
    add-apt-repository -y universe 2>/dev/null || true # mesa-utils (glxinfo, glxgears) lives in universe
    apt-get update
    apt-get install -y socat mesa-utils
    cat > /etc/systemd/system/macaroon-gl.service <<EOF
    [Unit]
    Description=Macaroon OpenGL bridge (Mesa vtest socket to the Mac over vsock)
    [Service]
    ExecStart=/usr/bin/socat UNIX-LISTEN:/run/macaroon-gl.sock,fork,mode=0666 VSOCK-CONNECT:2:\(port)
    Restart=always
    [Install]
    WantedBy=multi-user.target
    EOF
    cat > /usr/local/bin/macaroon-gl <<'EOF'
    #!/bin/sh
    # Runs a program with its OpenGL rendered on the Mac's GPU, e.g.: macaroon-gl glxgears
    export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=virpipe VTEST_SOCKET_NAME=/run/macaroon-gl.sock
    exec "$@"
    EOF
    chmod +x /usr/local/bin/macaroon-gl
    systemctl daemon-reload
    systemctl enable --now macaroon-gl.service
    echo "Done. Try: macaroon-gl glxinfo -B   and   macaroon-gl glxgears"

    """
}
