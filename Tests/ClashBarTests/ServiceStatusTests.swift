import Foundation
import XCTest
@testable import ClashBar

final class ServiceStatusTests: XCTestCase {
    func testFullURLValidationAndRequestIsolation() throws {
        let url = try XCTUnwrap(ServiceEndpoint.validatedURL(" https://example.com:8443/path?q=a%20b&x=2 "))
        XCTAssertEqual(url.absoluteString, "https://example.com:8443/path?q=a%20b&x=2")
        for value in ["example.com", "ftp://example.com/", "https://u:p@example.com/", "https://example.com:70000/", "https://example.com/\nheader"] {
            XCTAssertNil(ServiceEndpoint.validatedURL(value), value)
        }
        let args = ServiceStatusChecker.curlArguments(url: url, proxy: "http://127.0.0.1:7890", sourcePort: 55555)
        XCTAssertEqual(Array(args.suffix(2)), ["--", url.absoluteString])
        XCTAssertTrue(args.contains("--proxytunnel"))
        XCTAssertFalse(args.contains("--location"))
        XCTAssertEqual(args[args.firstIndex(of: "--noproxy")! + 1], "")
    }

    func testStatusClassificationKeepsResponsesSeparateFromFailures() {
        for code in [403, 429] {
            let result = ServiceStatusChecker.parsedResult(output: "\(code)\n0.2\n0.3\n200", error: "size limit", exit: 63)
            XCTAssertEqual(result.state, .restricted)
            XCTAssertEqual(result.statusCode, code)
        }
        XCTAssertEqual(ServiceStatusChecker.parsedResult(output: "200\n0.1\n8\n200", error: "timeout after headers", exit: 28).state, .reachable)
        XCTAssertEqual(ServiceStatusChecker.parsedResult(output: "000\n0\n8\n200", error: "timeout", exit: 28).state, .timedOut)
        XCTAssertEqual(ServiceStatusChecker.parsedResult(output: "000\n0\n0.1\n200", error: "TLS", exit: 60).state, .tlsFailed)
        XCTAssertEqual(ServiceStatusChecker.parsedResult(output: "000\n0\n0.1\n407", error: "proxy auth", exit: 56).state, .unavailable)
        XCTAssertEqual(ServiceStatusChecker.parsedResult(output: "000\n0\n0.1\n200", error: "connect", exit: 7).state, .connectionFailed)
    }

    func testConnectionAttributionRequiresUniqueFreshExactSource() {
        let now = Date()
        func connection(id: String = "new", port: Int = 55555, host: String = "example.com", timestamp: Date? = now) -> ConnectionSummary {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return ConnectionSummary(id: id, upload: nil, download: nil, start: timestamp.map(formatter.string),
                                     rule: "Domain", rulePayload: host, chains: ["Node", "Nested", "PROXY"],
                                     metadata: ConnectionMetadata(network: "tcp", sourceIP: "127.0.0.1", destinationIP: nil, host: host, sourcePort: port))
        }
        func match(_ values: [ConnectionSummary]) -> ConnectionSummary? {
            ServiceStatusChecker.correlatedConnection(values, baseline: ["old"], sourcePort: 55555, host: "example.com", startedAt: now)
        }
        XCTAssertEqual(match([connection()])?.id, "new")
        XCTAssertNil(match([connection(id: "old")]))
        XCTAssertNil(match([connection(port: 55556)]))
        XCTAssertNil(match([connection(host: "other.com")]))
        XCTAssertNil(match([connection(timestamp: now.addingTimeInterval(-10))]))
        XCTAssertNil(match([connection(timestamp: nil)]))
        XCTAssertNil(match([connection(), connection(id: "ambiguous")]))
        XCTAssertEqual(ServiceProbeResult(chains: ["Node", "Nested", "PROXY"]).routeDescription, "PROXY → Nested → Node")
        XCTAssertNil(ServiceProbeResult().routeDescription)
    }

    func testDirectConfigurationCannotUseFormalRulesOrTUN() throws {
        let network = ServiceDirectSession.Network(interface: "en0", dnsServers: ["192.168.1.1"])
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: ServiceDirectSession.configuration(network: network, port: 12345)) as? [String: Any])
        XCTAssertEqual(config["interface-name"] as? String, "en0")
        XCTAssertEqual(config["mode"] as? String, "direct")
        XCTAssertEqual((config["tun"] as? [String: Bool])?["enable"], false)
        XCTAssertEqual(config["rules"] as? [String], ["MATCH,DIRECT"])
        XCTAssertNil(config["proxy-groups"])
        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        XCTAssertEqual(dns["direct-nameserver"] as? [String], ["192.168.1.1#en0"])
        XCTAssertEqual(config["external-controller"] as? String, "")
        XCTAssertFalse(ServiceDirectSession.Network.isUsableDNS("127.0.0.1"))
        XCTAssertFalse(ServiceDirectSession.Network.isUsableDNS("198.18.0.1"))
        XCTAssertFalse(ServiceDirectSession.Network.isUsableDNS("169.254.1.1"))
        XCTAssertFalse(ServiceDirectSession.Network.isUsableDNS("fe80::1"))
        XCTAssertFalse(ServiceDirectSession.Network.isUsableDNS("::ffff:127.0.0.1"))
        XCTAssertFalse(ServiceDirectSession.Network.isUsableDNS("ff02::1"))
        XCTAssertTrue(ServiceDirectSession.Network.isUsableDNS("2001:4860:4860::8888"))
        XCTAssertTrue(ServiceDirectSession.Network.isUsableDNS("192.168.1.1"))
    }
}

@MainActor
final class ServiceStatusViewModelTests: XCTestCase {
    private func storage() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("services.json")
    }

    func testOnlyCustomServicesPersistAndBuiltInsCannotBeDeleted() throws {
        let path = storage()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = ServiceStatusViewModel(storageURL: path)
        XCTAssertEqual(model.services, ServiceEndpoint.builtIns)
        model.delete(model.services[0])
        XCTAssertEqual(model.services.count, 3)
        try model.add(name: "Company", url: "https://example.com/path?q=1")
        let custom = try XCTUnwrap(model.services.last)
        let reloaded = ServiceStatusViewModel(storageURL: path)
        XCTAssertEqual(reloaded.services.count, 4)
        XCTAssertEqual(reloaded.services.last, custom)
        let saved = try JSONDecoder().decode([ServiceEndpoint].self, from: Data(contentsOf: path))
        XCTAssertEqual(saved, [custom])
        reloaded.delete(custom)
        XCTAssertEqual(ServiceStatusViewModel(storageURL: path).services, ServiceEndpoint.builtIns)
    }

    func testCorruptStorageIsReportedAndNeverOverwritten() throws {
        let path = storage()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("invalid json".utf8)
        try original.write(to: path)
        let model = ServiceStatusViewModel(storageURL: path)
        XCTAssertNotNil(model.storageError)
        XCTAssertThrowsError(try model.add(name: "Company", url: "https://example.com/"))
        XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual(model.services.count, 3)
    }

    func testCancellationKeepsCompletedMeasurementAndAwaitsCleanupBeforeRetry() async throws {
        let path = storage()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = ServiceStatusViewModel(storageURL: path)
        let checker = PartialServiceChecker()
        model.start(checker: checker)
        try await waitUntil { model.results[ServiceEndpoint.builtIns[0].id]?.current.state == .reachable }
        model.cancel()
        XCTAssertEqual(model.results[ServiceEndpoint.builtIns[0].id]?.current.state, .reachable)
        XCTAssertEqual(model.results[ServiceEndpoint.builtIns[0].id]?.direct.state, .cancelled)
        XCTAssertEqual(model.results[ServiceEndpoint.builtIns[1].id]?.current.state, .cancelled)
        try await waitUntil { !model.isRunning }
        let closed = await checker.closed
        XCTAssertTrue(closed)
        XCTAssertNotNil(model.lastCheckedAt)
        model.start(checker: CompletedServiceChecker())
        try await waitUntil { !model.isRunning }
        XCTAssertTrue(model.lastRunCompleted)
        XCTAssertEqual(model.completedCount, 3)
    }

    func testRoutingChangesInvalidateResultsButNewServicesRemainPending() async throws {
        let path = storage()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = ServiceStatusViewModel(storageURL: path)
        model.acceptRoutingFingerprint(ServiceRoutingFingerprint(value: "before"))
        model.start(checker: CompletedServiceChecker())
        try await waitUntil { !model.isRunning }
        try model.add(name: "New", url: "https://example.com/")
        let newID = try XCTUnwrap(model.services.last?.id)
        model.acceptRoutingFingerprint(ServiceRoutingFingerprint(value: "after"))
        XCTAssertTrue(model.hasStaleResults)
        XCTAssertTrue(model.results[ServiceEndpoint.builtIns[0].id]?.current.isStale == true)
        XCTAssertNil(model.results[newID])
        XCTAssertNotNil(model.lastCheckedAt)
        model.delete(model.services.last!)
        XCTAssertNil(model.results[newID])
        XCTAssertEqual(model.services.count, 3)
    }

    func testUnavailableRoutingSnapshotsStillPermitIndependentMeasurements() async throws {
        let path = storage()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let model = ServiceStatusViewModel(storageURL: path)
        model.start(checker: CompletedServiceChecker(), routingClient: UnavailableRoutingClient())
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.completedCount, 3)
        XCTAssertEqual(model.results[ServiceEndpoint.builtIns[0].id]?.direct.state, .reachable)
        XCTAssertTrue(model.hasStaleResults)
        XCTAssertTrue(model.routingVerificationFailed)
        XCTAssertFalse(model.lastRunCompleted)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for service status task")
    }
}

private struct UnavailableRoutingClient: MihomoAPITransporting {
    func request<T: Decodable>(_ endpoint: Endpoint) async throws -> T { throw URLError(.cannotConnectToHost) }
    func requestNoResponse(_ endpoint: Endpoint) async throws { throw URLError(.cannotConnectToHost) }
}

actor CompletedServiceChecker: ServiceStatusChecking {
    func prepare() async throws {}
    func measure(_ endpoint: ServiceEndpoint, kind: ServiceProbeKind) async throws -> ServiceProbeResult {
        ServiceProbeResult(state: endpoint.name == "YouTube" ? .restricted : .reachable,
                           statusCode: endpoint.name == "YouTube" ? 403 : 200,
                           elapsed: kind == .current ? 0.38 : 0.62,
                           chains: kind == .current ? ["Node", "PROXY"] : ["DIRECT"], checkedAt: Date())
    }
    func close() async {}
}

private actor PartialServiceChecker: ServiceStatusChecking {
    private(set) var closed = false
    func prepare() async throws {}
    func measure(_ endpoint: ServiceEndpoint, kind: ServiceProbeKind) async throws -> ServiceProbeResult {
        if kind == .direct { try await Task.sleep(for: .seconds(30)) }
        return ServiceProbeResult(state: .reachable, statusCode: 200, chains: ["DIRECT"], checkedAt: Date())
    }
    func close() async { closed = true }
}
