import Darwin
import Foundation

final class AgentRuleSocket: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (AgentRuleRequest) async -> AgentRuleResponse

    private let directory: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "ClashBar.agent-rules.accept")
    private var listener: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private var socketPath: String { directory.appendingPathComponent("rules.sock").path }

    init(stateDirectory: URL, handler: @escaping Handler) {
        directory = stateDirectory.appendingPathComponent("agent", isDirectory: true)
        self.handler = handler
    }

    func start() throws {
        guard listener == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
            throw failure("Agent directory must belong to the current user and be private.")
        }
        let lockPath = directory.appendingPathComponent("service.lock").path
        let lock = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw failure("Unable to open agent service lock.") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw failure("Another ClashBar agent service is already running.")
        }
        var fd: Int32 = -1
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketPath.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw failure("Agent socket path is too long.")
            }
            if lstat(socketPath, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
                    throw failure("Existing agent socket path is not a socket owned by this user.")
                }
                guard unlink(socketPath) == 0 else { throw failure("Unable to remove stale agent socket.") }
            } else if errno != ENOENT {
                throw failure("Unable to inspect agent socket path.")
            }
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw failure("Unable to create agent socket.") }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw failure("Unable to bind agent socket.") }
            guard chmod(socketPath, 0o600) == 0, listen(fd, 16) == 0 else {
                unlink(socketPath)
                throw failure("Unable to start agent socket.")
            }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptClients(fd) }
            source.setCancelHandler { close(fd) }
            lockFD = lock
            listener = source
            source.resume()
        } catch {
            if fd >= 0 { close(fd) }
            close(lock)
            throw error
        }
    }

    func stop() {
        guard let listener else { return }
        self.listener = nil
        listener.cancel()
        unlink(socketPath)
        close(lockFD)
        lockFD = -1
    }

    private func acceptClients(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            let flags = fcntl(client, F_GETFL)
            guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
                close(client)
                continue
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            DispatchQueue.global(qos: .utility).async { [handler] in
                Self.receive(client, handler: handler)
            }
        }
    }

    private static func receive(_ fd: Int32, handler: @escaping Handler) {
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= 262_144 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { close(fd); return }
            data.append(contentsOf: buffer.prefix(count))
            if let newline = data.firstIndex(of: 10) {
                data = data.prefix(upTo: newline)
                break
            }
        }
        guard data.count <= 262_144, let request = try? JSONDecoder().decode(AgentRuleRequest.self, from: data) else {
            sendResponse(.failure("invalid_request", "Expected a JSON request of at most 256 KiB."), to: fd)
            return
        }
        Task { @MainActor in
            let response = await handler(request)
            DispatchQueue.global(qos: .utility).async { sendResponse(response, to: fd) }
        }
    }

    private static func sendResponse(_ response: AgentRuleResponse, to fd: Int32) {
        defer { close(fd) }
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(10)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { break }
                offset += count
            }
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "ClashBar.AgentRules", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
