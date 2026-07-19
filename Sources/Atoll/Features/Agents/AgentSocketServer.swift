import Foundation
import Darwin

/// AF_UNIX SOCK_STREAM server at /tmp/atoll.sock receiving one JSON envelope
/// per hook invocation. PermissionRequest connections are held open so the app
/// can write a hook-decision JSON back (the hook script prints it to stdout and
/// the CLI consumes it). Everything runs on a private utility queue; envelopes
/// are delivered on the main queue.
final class AgentSocketServer {

    static let socketPath = "/tmp/atoll.sock"

    /// Called on the main queue for every decoded envelope.
    /// `replyKey` is non-nil when the connection is being held open for a
    /// permission decision (resolve it with `resolvePermission(key:responseJSON:)`).
    var onEnvelope: ((AgentHookEnvelope, _ replyKey: String?) -> Void)?
    /// Called on the main queue when a held PermissionRequest reply times out
    /// (the CLI falls back to its own prompt; the UI must drop the stale card).
    var onPermissionExpired: ((_ replyKey: String) -> Void)?

    private let queue = DispatchQueue(label: "com.atoll.agents.socket", qos: .utility)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    private final class Connection {
        let fd: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        var handledEnvelope = false
        /// When true the fd outlives the read source (pending permission reply).
        var held = false
        init(fd: Int32) { self.fd = fd }
    }

    private struct PendingReply {
        let fd: Int32
        let timer: DispatchSourceTimer
    }

    private var connections: [Int32: Connection] = [:]
    private var pendingReplies: [String: PendingReply] = [:]

    /// Seconds we hold a PermissionRequest connection before giving up.
    /// Slightly above the script's 290s recv timeout is pointless — keep just under
    /// it so the script sees a clean EOF and falls back to the CLI's own prompt.
    private let permissionTimeout: TimeInterval = 290

    private let maxLineBytes = 1 << 20 // 1 MB safety cap per envelope

    deinit { stop() }

    // MARK: - Lifecycle

    /// Bind and start accepting. Returns false if another live server owns the socket
    /// (e.g. a second Atoll instance) or the socket could not be created.
    @discardableResult
    func start() -> Bool {
        var ok = false
        queue.sync { ok = self.startLocked() }
        return ok
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            if listenFD >= 0 {
                close(listenFD)
                listenFD = -1
                unlink(AgentSocketServer.socketPath)
            }
            for (_, conn) in connections {
                // Held fds are owned by pendingReplies (closed below); the cancel
                // handler skips closing them, avoiding a double close.
                conn.source?.cancel()
            }
            connections.removeAll()
            for (_, pending) in pendingReplies {
                pending.timer.cancel()
                close(pending.fd)
            }
            pendingReplies.removeAll()
        }
    }

    private func startLocked() -> Bool {
        guard listenFD < 0 else { return true }

        // Stale-socket probe: if a connect succeeds another server is live; if it
        // fails with ECONNREFUSED the file is a stale leftover and safe to unlink.
        if FileManager.default.fileExists(atPath: AgentSocketServer.socketPath) {
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            if probe >= 0 {
                let result = AgentSocketServer.withSockaddrUn(AgentSocketServer.socketPath) { sa, len in
                    connect(probe, sa, len)
                }
                let err = errno
                close(probe)
                if result == 0 {
                    NSLog("Atoll: another process is already serving \(AgentSocketServer.socketPath); socket server not started")
                    return false
                }
                if err != ECONNREFUSED && err != ENOENT {
                    NSLog("Atoll: unexpected errno \(err) probing agent socket; unlinking anyway")
                }
            }
            unlink(AgentSocketServer.socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("Atoll: socket() failed: \(String(cString: strerror(errno)))")
            return false
        }

        let bindResult = AgentSocketServer.withSockaddrUn(AgentSocketServer.socketPath) { sa, len in
            bind(fd, sa, len)
        }
        guard bindResult == 0 else {
            NSLog("Atoll: bind(\(AgentSocketServer.socketPath)) failed: \(String(cString: strerror(errno)))")
            close(fd)
            return false
        }
        chmod(AgentSocketServer.socketPath, 0o600)

        guard listen(fd, 16) == 0 else {
            NSLog("Atoll: listen failed: \(String(cString: strerror(errno)))")
            close(fd)
            unlink(AgentSocketServer.socketPath)
            return false
        }

        AgentSocketServer.setNonBlocking(fd)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        acceptSource = source
        NSLog("Atoll: agent socket listening at \(AgentSocketServer.socketPath)")
        return true
    }

    // MARK: - Accept / read

    private func acceptPending() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                // EAGAIN/EWOULDBLOCK = drained; anything else is transient.
                return
            }
            AgentSocketServer.setNonBlocking(clientFD)
            var noSigpipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            let conn = Connection(fd: clientFD)
            let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
            source.setEventHandler { [weak self, weak conn] in
                guard let self, let conn else { return }
                self.readAvailable(conn)
            }
            source.setCancelHandler { [weak self, weak conn] in
                guard let conn else { return }
                if !conn.held { close(conn.fd) }
                self?.connections.removeValue(forKey: conn.fd)
            }
            connections[clientFD] = conn
            conn.source = source
            source.resume()
        }
    }

    private func readAvailable(_ conn: Connection) {
        var sawEOF = false
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(conn.fd, &chunk, chunk.count)
            if n > 0 {
                conn.buffer.append(contentsOf: chunk[0..<n])
                if conn.buffer.count > maxLineBytes {
                    conn.source?.cancel()
                    return
                }
            } else if n == 0 {
                sawEOF = true
                break
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                if errno == EINTR { continue }
                sawEOF = true
                break
            }
        }

        // Envelopes are newline-terminated; the client may also shutdown(WR) right
        // after sending, so EOF with a non-empty buffer is a complete envelope too.
        while let newline = conn.buffer.firstIndex(of: 0x0A) {
            let lineData = conn.buffer.prefix(upTo: newline)
            conn.buffer.removeSubrange(...newline)
            handleLine(Data(lineData), conn: conn)
            if conn.handledEnvelope { break }
        }
        if sawEOF {
            if !conn.handledEnvelope, !conn.buffer.isEmpty {
                handleLine(conn.buffer, conn: conn)
                conn.buffer.removeAll()
            }
            conn.source?.cancel()
        }
    }

    private func handleLine(_ data: Data, conn: Connection) {
        guard !conn.handledEnvelope else { return }
        let trimmed = data
        guard !trimmed.isEmpty, let envelope = AgentHookEnvelope(jsonLine: trimmed) else { return }
        conn.handledEnvelope = true

        var replyKey: String?
        if envelope.event == "PermissionRequest" {
            let key = envelope.permissionReplyKey
            replyKey = key

            // Detach the fd from the read source and park it until a decision
            // arrives or the timeout fires. On timeout we write NOTHING and just
            // close: the hook script's recv gets EOF, prints nothing, and the CLI
            // falls back to its own interactive prompt.
            conn.held = true
            conn.source?.cancel()

            // Replace any stray pending entry for the same key.
            if let stale = pendingReplies.removeValue(forKey: key) {
                stale.timer.cancel()
                close(stale.fd)
            }

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + permissionTimeout)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if let pending = self.pendingReplies.removeValue(forKey: key) {
                    pending.timer.cancel()
                    close(pending.fd)
                    DispatchQueue.main.async { [weak self] in
                        self?.onPermissionExpired?(key)
                    }
                }
            }
            timer.resume()
            pendingReplies[key] = PendingReply(fd: conn.fd, timer: timer)
        } else {
            // One envelope per connection; we can close as soon as it is handled.
            conn.source?.cancel()
        }

        let keyForCallback = replyKey
        DispatchQueue.main.async { [weak self] in
            self?.onEnvelope?(envelope, keyForCallback)
        }
    }

    // MARK: - Permission resolution

    /// Write a hook-decision JSON back to a held PermissionRequest connection
    /// and close it. Safe to call from any thread. No-op if the key expired.
    func resolvePermission(key: String, responseJSON: String) {
        queue.async { [weak self] in
            guard let self, let pending = self.pendingReplies.removeValue(forKey: key) else { return }
            pending.timer.cancel()
            var bytes = Array(responseJSON.utf8)
            if bytes.last != 0x0A { bytes.append(0x0A) }
            var offset = 0
            while offset < bytes.count {
                let n = bytes[offset...].withUnsafeBytes { buf -> Int in
                    write(pending.fd, buf.baseAddress, buf.count)
                }
                if n <= 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        usleep(10_000)
                        continue
                    }
                    break
                }
                offset += n
            }
            close(pending.fd)
        }
    }

    /// Whether a permission reply is still pending for this key.
    func hasPendingReply(key: String) -> Bool {
        var result = false
        queue.sync { result = self.pendingReplies[key] != nil }
        return result
    }

    // MARK: - Helpers

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    private static func withSockaddrUn(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= maxLen else { return -1 }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() {
                raw[i] = b
            }
            raw[pathBytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                body(sa, len)
            }
        }
    }
}
