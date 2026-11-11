import Foundation
import Darwin
import XCTest
import Yams
@testable import ClashBar

final class ServiceStatusIntegrationTests: XCTestCase {
    /// Explicit opt-in only. Reads the running local core and makes six public
    /// HTTP requests; never changes its mode, groups, rules or network settings.
    func testLiveBuiltInServicesWithoutChangingCore() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLASHBAR_SERVICE_LIVE_CONFIG"] else {
            throw XCTSkip("Set CLASHBAR_SERVICE_LIVE_CONFIG to opt into public service checks")
        }
        let config = try XCTUnwrap(try Yams.load(yaml: String(contentsOfFile: path, encoding: .utf8)) as? [String: Any])
        let controller = ProcessInfo.processInfo.environment["CLASHBAR_SERVICE_LIVE_CONTROLLER"] ?? config["external-controller"] as? String ?? "127.0.0.1:9090"
        let client = MihomoAPIService(controller: controller, secret: config["secret"] as? String)
        let state: ConfigSnapshot = try await client.request(.getConfigs)
        let before = try await ServiceRoutingFingerprint.load(client: client)
        let checker = ServiceStatusChecker(client: client, binary: try binaryURL(), local: true, running: true)
        try await checker.prepare()
        print("Live service check: TUN enabled = \(state.tun?.enable == true)")
        do {
            for endpoint in ServiceEndpoint.builtIns {
                async let currentTask = checker.measure(endpoint, kind: .current)
                async let directTask = checker.measure(endpoint, kind: .direct)
                let (current, direct) = try await (currentTask, directTask)
                for (kind, result) in [("current", current), ("direct", direct)] {
                    print("\(endpoint.name) \(kind): \(result.state), HTTP \(result.statusCode.map(String.init) ?? "none"), route \(result.routeDescription ?? "unconfirmed")")
                    XCTAssertFalse([.pending, .checking, .cancelled].contains(result.state))
                }
            }
            let after = try await ServiceRoutingFingerprint.load(client: client)
            XCTAssertEqual(before, after, "Read-only checks must preserve the running core")
            await checker.close()
        } catch { await checker.close(); throw error }
    }

    func testActualRequestsDistinguishRestrictedResponsesAndIndependentDirect() async throws {
        let binary = try binaryURL()
        let server = try await ServiceHTTPFixture.start()
        defer { server.stop() }
        let core = try await ServiceCoreFixture.start(binary: binary, reject: true)
        defer { core.stop() }
        let before: ServiceRoutingFingerprint = try await .load(client: core.client)
        let checker = ServiceStatusChecker(client: core.client, binary: binary, local: true, running: true)
        try await checker.prepare()
        do {
            // The ordinary core rejects every request. DIRECT must still reach
            // the origin, with the path and query preserved byte for byte.
            for code in [200, 403, 429] {
                let endpoint = ServiceEndpoint(id: "test", name: "Fixture", url: "http://127.0.0.1:\(server.port)/\(code)/full/path?q=one%20two&x=3")
                let current = try await checker.measure(endpoint, kind: .current)
                XCTAssertNil(current.statusCode, "A proxy-generated failure is not an origin response")
                XCTAssertEqual(current.state, .connectionFailed)
                let direct = try await checker.measure(endpoint, kind: .direct)
                XCTAssertEqual(direct.statusCode, code)
                XCTAssertEqual(direct.state, code == 200 ? .reachable : .restricted)
                XCTAssertEqual(direct.chains, ["DIRECT"])
            }
            let after = try await ServiceRoutingFingerprint.load(client: core.client)
            XCTAssertEqual(before, after, "Checks must not mutate the formal core's routing inputs")
            let requests = try String(contentsOf: server.requests, encoding: .utf8).split(separator: "\n").map(String.init)
            XCTAssertEqual(requests.count, 3)
            XCTAssertTrue(requests.allSatisfy { $0.hasSuffix("/full/path?q=one%20two&x=3") })
            await checker.close()
        } catch { await checker.close(); throw error }
    }

    func testObservedChainAndTwoMeasurementsWhenBothUseDirect() async throws {
        let binary = try binaryURL()
        let server = try await ServiceHTTPFixture.start()
        defer { server.stop() }
        let core = try await ServiceCoreFixture.start(binary: binary, reject: false)
        defer { core.stop() }
        let checker = ServiceStatusChecker(client: core.client, binary: binary, local: true, running: true)
        try await checker.prepare()
        do {
            let endpoint = ServiceEndpoint(id: "test", name: "Fixture", url: "http://127.0.0.1:\(server.port)/200/slow?q=1")
            let current = try await checker.measure(endpoint, kind: .current)
            let direct = try await checker.measure(endpoint, kind: .direct)
            XCTAssertEqual(current.statusCode, 200)
            XCTAssertEqual(current.chains, ["DIRECT", "Nested", "Policy"])
            XCTAssertEqual(current.routeDescription, "Policy → Nested → DIRECT")
            XCTAssertEqual(direct.statusCode, 200)
            XCTAssertEqual(direct.chains, ["DIRECT"])
            let requests = try String(contentsOf: server.requests, encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(requests.count, 2, "Even identical DIRECT routes require independent requests")
            // No API attribution means unknown, even though HTTP succeeded.
            let unknown = try await ServiceStatusChecker.request(url: URL(string: endpoint.url)!, proxy: "http://127.0.0.1:\(core.port)", client: nil, forcedDirect: false)
            XCTAssertEqual(unknown.statusCode, 200)
            XCTAssertNil(unknown.routeDescription)
            await checker.close()
        } catch { await checker.close(); throw error }
    }

    func testCancellationStopsCurlAndDisposesDirectCore() async throws {
        let binary = try binaryURL()
        let server = try await ServiceHTTPFixture.start()
        defer { server.stop() }
        let direct = try await ServiceDirectSession.start(binary: binary)
        let task = Task {
            try await ServiceStatusChecker.request(url: URL(string: "http://127.0.0.1:\(server.port)/200/hang")!,
                                                  proxy: "socks5h://127.0.0.1:\(direct.proxyPort)", client: nil, forcedDirect: true)
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: server.requests.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await direct.close()
        // An already closed session is safely idempotent.
        await direct.close()
    }

    private func binaryURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"] else {
            throw XCTSkip("Set CLASHBAR_TEST_MIHOMO to run isolated real-core checks")
        }
        return URL(fileURLWithPath: path)
    }
}

private final class ServiceCoreFixture: @unchecked Sendable {
    let process: Process
    let directory: URL
    let client: MihomoAPIService
    let port: Int
    private let log: FileHandle

    private init(process: Process, directory: URL, client: MihomoAPIService, port: Int, log: FileHandle) {
        self.process = process; self.directory = directory; self.client = client; self.port = port; self.log = log
    }

    static func start(binary: URL, reject: Bool) async throws -> ServiceCoreFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clashbar-status-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let proxyPort = try ServiceDirectSession.unusedLoopbackPort()
        let controllerPort = try ServiceDirectSession.unusedLoopbackPort()
        let controller = "127.0.0.1:\(controllerPort)"
        let config = directory.appendingPathComponent("config.yaml")
        try Data("""
        mixed-port: \(proxyPort)
        bind-address: 127.0.0.1
        external-controller: \(controller)
        mode: rule
        log-level: silent
        proxy-groups:
          - {name: Policy, type: select, proxies: [Nested]}
          - {name: Nested, type: select, proxies: [DIRECT]}
        rules: ['MATCH,\(reject ? "REJECT" : "Policy")']
        """.utf8).write(to: config)
        let process = Process()
        let logURL = directory.appendingPathComponent("core.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        process.executableURL = try ServiceDirectSession.copyUnprivilegedBinary(binary, into: directory)
        process.arguments = ["-d", directory.path, "-f", config.path]
        process.standardOutput = log; process.standardError = log
        let client = MihomoAPIService(controller: controller, secret: nil)
        let owned = ServiceCoreFixture(process: process, directory: directory, client: client, port: proxyPort, log: log)
        do {
            try process.run()
            for _ in 0..<40 {
                if let _: VersionInfo = try? await client.request(.version) { return owned }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw CocoaError(.executableLoad)
        } catch { owned.stop(); throw error }
    }

    func stop() {
        if process.isRunning { kill(process.processIdentifier, SIGTERM) }
        try? log.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ServiceHTTPFixture: @unchecked Sendable {
    let process: Process
    let directory: URL
    let port: Int
    var requests: URL { directory.appendingPathComponent("requests") }
    private init(process: Process, directory: URL, port: Int) { self.process = process; self.directory = directory; self.port = port }

    static func start() async throws -> ServiceHTTPFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clashbar-http-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("server.py")
        try Data("""
        import http.server, pathlib, sys, time
        root = pathlib.Path(sys.argv[1])
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                with (root / 'requests').open('a') as f: f.write(self.path + '\\n')
                time.sleep(15 if '/hang' in self.path else 0.3)
                self.send_response(int(self.path.split('/')[1]))
                self.send_header('Content-Length', '1')
                self.end_headers()
                try: self.wfile.write(b'x')
                except (BrokenPipeError, ConnectionResetError): pass
            def log_message(self, *args): pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        (root / 'port').write_text(str(server.server_port))
        server.serve_forever()
        """.utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if let value = try? String(contentsOf: directory.appendingPathComponent("port"), encoding: .utf8), let port = Int(value) {
                return ServiceHTTPFixture(process: process, directory: directory, port: port)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning { kill(process.processIdentifier, SIGTERM) }
        try? FileManager.default.removeItem(at: directory)
        throw CocoaError(.executableLoad)
    }

    func stop() {
        if process.isRunning { kill(process.processIdentifier, SIGTERM) }
        try? FileManager.default.removeItem(at: directory)
    }
}
