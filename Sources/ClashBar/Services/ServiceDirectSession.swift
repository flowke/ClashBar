import AppKit
import Darwin
import Foundation
import SystemConfiguration

/// A second, disposable core. Its only outbound is DIRECT, and both its DNS and
/// outbound sockets are bound to a verified hardware interface. On Darwin Mihomo
/// implements interface-name using IP_BOUND_IF / IPV6_BOUND_IF, bypassing TUN
/// routes without changing the managed core or the machine's network settings.
final class ServiceDirectSession: @unchecked Sendable {
    struct Network: Equatable, Sendable {
        let interface: String
        let dnsServers: [String]
        var signature = ""

        static func physical() throws -> Self {
            guard let store = SCDynamicStoreCreate(nil, "ClashBar service status" as CFString, nil, nil) else {
                throw DirectError.networkUnavailable
            }
            let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
            for family in ["IPv4", "IPv6"] {
                guard let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
                      let name = global["PrimaryInterface"] as? String,
                      let service = global["PrimaryService"] as? String,
                      if_nametoindex(name) != 0,
                      interfaces.contains(where: {
                          SCNetworkInterfaceGetBSDName($0) as String? == name &&
                              [kSCNetworkInterfaceTypeEthernet as String, kSCNetworkInterfaceTypeIEEE80211 as String]
                              .contains(SCNetworkInterfaceGetInterfaceType($0) as String?)
                      }) else { continue }
                // Read the hardware service's DNS, never the global resolver
                // which may have been replaced by TUN / fake-IP DNS.
                for domain in ["State", "Setup"] {
                    let dns = SCDynamicStoreCopyValue(store, "\(domain):/Network/Service/\(service)/DNS" as CFString) as? [String: Any]
                    let servers = (dns?["ServerAddresses"] as? [String] ?? []).filter(Self.isUsableDNS)
                    if !servers.isEmpty {
                        let addressing = ["IPv4", "IPv6"].map { family in
                            let state = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/\(family)" as CFString) as? [String: Any]
                            return (state?["Addresses"] as? [String] ?? []).sorted().joined(separator: ",") + ":" + (state?["Router"] as? String ?? "")
                        }.joined(separator: "|")
                        return Self(interface: name, dnsServers: servers,
                                    signature: "\(service)|\(addressing)")
                    }
                }
            }
            throw DirectError.networkUnavailable
        }

        static func isUsableDNS(_ value: String) -> Bool {
            var v4 = in_addr()
            var v6 = in6_addr()
            if inet_pton(AF_INET, value, &v4) == 1 {
                let ip = UInt32(bigEndian: v4.s_addr)
                // Darwin Mihomo binds unicast sockets. Do not accept local
                // resolver stubs, link-local / multicast or fake-IP DNS.
                return ip >> 24 != 127 && ip >> 24 != 0 && ip != UInt32.max &&
                    ip & 0xffff0000 != 0xa9fe0000 && ip & 0xf0000000 != 0xe0000000 &&
                    ip & 0xfffe0000 != 0xc6120000
            }
            if inet_pton(AF_INET6, value, &v6) == 1 {
                return withUnsafeBytes(of: v6) { bytes in
                    let local = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] <= 1
                    let linkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
                    let mappedIPv4 = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
                    return !local && !linkLocal && !mappedIPv4 && bytes[0] != 0xff
                }
            }
            return false
        }
    }

    enum DirectError: LocalizedError {
        case networkUnavailable, coreUnavailable, startupFailed
        var errorDescription: String? {
            switch self {
            case .networkUnavailable: "无法确认物理网络接口及其 DNS，不能保证绕过 TUN。 / Physical interface and DNS could not be verified."
            case .coreUnavailable: "本地 Mihomo 核心不可用，无法建立强制直连。 / Local Mihomo binary is unavailable."
            case .startupFailed: "独立直连核心未能启动，未执行直连请求。 / The isolated DIRECT core could not start."
            }
        }
    }

    let proxyPort: Int
    let network: Network
    var isRunning: Bool { process.isRunning }
    private let process: Process
    private let directory: URL
    private let log: FileHandle
    private var terminationObserver: NSObjectProtocol?

    private init(proxyPort: Int, network: Network, process: Process, directory: URL, log: FileHandle) {
        self.proxyPort = proxyPort
        self.network = network
        self.process = process
        self.directory = directory
        self.log = log
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func configuration(network: Network, port: Int) throws -> Data {
        // JSON is a YAML subset; serialization prevents values being interpreted
        // as YAML syntax. No provider, proxy group, persisted cache or TUN exists.
        try JSONSerialization.data(withJSONObject: [
            "mixed-port": port, "bind-address": "127.0.0.1", "allow-lan": false,
            "mode": "direct", "log-level": "info", "ipv6": true,
            "interface-name": network.interface, "external-controller": "",
            "profile": ["store-selected": false, "store-fake-ip": false],
            "tun": ["enable": false], "rules": ["MATCH,DIRECT"],
            "dns": ["enable": true, "listen": "", "enhanced-mode": "normal", "use-hosts": false,
                    "nameserver": network.dnsServers.map { "\($0)#\(network.interface)" },
                    "direct-nameserver": network.dnsServers.map { "\($0)#\(network.interface)" }],
        ], options: [.sortedKeys])
    }

    static func start(binary: URL, network: Network? = nil) async throws -> ServiceDirectSession {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw DirectError.coreUnavailable }
        let network = try network ?? Network.physical()
        let port = try unusedLoopbackPort()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clashbar-direct-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let config = directory.appendingPathComponent("config.yaml")
        let logURL = directory.appendingPathComponent("core.log")
        let process = Process()
        var session: ServiceDirectSession?
        do {
            try configuration(network: network, port: port).write(to: config, options: .atomic)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            let owned = ServiceDirectSession(proxyPort: port, network: network, process: process, directory: directory, log: log)
            session = owned
            // The managed core may be setuid for TUN. This helper needs no
            // privileges: execute a private copy with all setuid bits removed.
            process.executableURL = try copyUnprivilegedBinary(binary, into: directory)
            process.arguments = ["-d", directory.path, "-f", config.path]
            process.standardOutput = log
            process.standardError = log
            // Do not inherit environment proxy settings or alternate core config.
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path]
            try process.run()
            for _ in 0..<100 {
                try Task.checkCancellation()
                guard process.isRunning else { throw DirectError.startupFailed }
                // A successful TCP connect alone could be another process that
                // won the port allocation race. Require this child's bind log.
                let startupLog = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                if startupLog.contains("Mixed(http+socks) proxy listening at: 127.0.0.1:\(port)"),
                   loopbackAcceptsConnections(port: port) { return owned }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw DirectError.startupFailed
        } catch {
            if let session { await session.close() }
            else { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }

    func close() async {
        if process.isRunning { process.terminate() }
        await ServiceProbeProcess.waitForExit(process)
        try? log.close()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? log.close()
        try? FileManager.default.removeItem(at: directory)
    }

    static func copyUnprivilegedBinary(_ binary: URL, into directory: URL) throws -> URL {
        let copy = directory.appendingPathComponent("mihomo")
        try FileManager.default.copyItem(at: binary, to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: copy.path)
        return copy
    }

    static func unusedLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        var address = loopbackAddress(port: 0)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func loopbackAddress(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        return address
    }

    private static func loopbackAcceptsConnections(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = loopbackAddress(port: port)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}

/// Cancellation waits for process exit before the run can be used again.
enum ServiceProbeProcess {
    static func terminateOnAppExit(_ process: Process) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    static func waitForExit(_ process: Process) async {
        guard process.processIdentifier > 0 else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // curl and Mihomo normally exit on SIGTERM immediately. Enforce
                // a bound even if a future binary stops handling SIGTERM.
                let deadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                // isRunning becomes false after Foundation has reaped the
                // child. waitUntilExit on a different thread can strand its
                // private run loop when the process has already exited.
                while process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
                continuation.resume()
            }
        }
    }
}
