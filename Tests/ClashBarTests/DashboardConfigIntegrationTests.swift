import Foundation
import XCTest
@testable import ClashBar

private final class TestCore: MihomoControlling, @unchecked Sendable {
    var status: CoreLifecycleStatus { .stopped }
    var isRunning: Bool { false }
    var detectedBinaryPath: String? { nil }
    var rejectValidation = false
    func validateConfigAsync(configPath: String) async throws {
        if rejectValidation { throw CocoaError(.fileReadCorruptFile) }
    }
    func startAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus { .stopped }
    func stop() {}
    func stopAsync() async {}
    func restartAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus { .stopped }
}

@MainActor
final class DashboardConfigIntegrationTests: XCTestCase {
    func testAgentSocketSendsLargeResponse() async throws {
        let root = URL(fileURLWithPath: "/tmp/cb-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rules = (0..<2000).map { "DOMAIN,host\($0).example,DIRECT" }
        let socket = AgentRuleSocket(stateDirectory: root) { _ in
            AgentRuleResponse(ok: true, code: nil, message: nil,
                              snapshot: AgentRuleSnapshot(revision: "test", baseName: "test.yaml",
                                                          coreRunning: false, changes: [], baseRules: rules,
                                                          effectiveRules: rules, policies: ["DIRECT"]))
        }
        try socket.start()
        defer { socket.stop() }
        let result = try await runAgentClient(root.appendingPathComponent("agent/rules.sock").path, ["list"])
        let snapshot = try XCTUnwrap(result["snapshot"] as? [String: Any])
        XCTAssertEqual((snapshot["effectiveRules"] as? [String])?.count, rules.count)
    }

    func testSwitchAndValidationFailurePreserveEffectiveConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = WorkingDirectoryManager(homeDirectory: root)
        try directory.bootstrapDirectories()
        for name in ["First.yaml", "Second.yaml"] {
            try Data("rules: ['MATCH,DIRECT']".utf8).write(to: directory.configDirectoryURL.appendingPathComponent(name))
        }
        let session = URLSessionFactory.makeEphemeralSession(options: .init(timeoutIntervalForRequest: 15, timeoutIntervalForResource: 30))
        defer { session.invalidateAndCancel() }
        let service = ConfigService(configManager: ConfigDirectoryManager(workingDirectoryManager: directory), configImportService: ConfigImportService())
        service.setConfigDirectory(directory.configDirectoryURL)
        let core = TestCore()
        let dependencies = AppDependencies(
            processManager: core, configService: service,
            systemProxyService: SystemProxyService(), tunPermissionService: TunPermissionService(),
            launchAtLoginService: AppLaunchService(), workingDirectoryManager: directory,
            networkReachabilityMonitor: NetworkReachabilityMonitor(), ssidMonitorService: SSIDMonitorService(),
            remoteMachineStore: RemoteMachineStore(session: session),
            proxyGroupIconCache: ProxyGroupIconCache(iconDirectory: directory.iconDirectoryURL, session: session),
            webUIAssetService: WebUIAssetService(workingDirectoryManager: directory, session: session),
            clashbarLogStore: AppLogStore(logFileURL: directory.logsDirectoryURL.appendingPathComponent("clashbar.log")),
            mihomoLogStore: AppLogStore(logFileURL: directory.logsDirectoryURL.appendingPathComponent("mihomo.log")))
        let model = AppViewModel(dependencies: dependencies)
        let firstApplied = await model.applyDashboardConfiguration(baseName: "First.yaml", changes: [])
        XCTAssertTrue(firstApplied, model.dashboardConfigError ?? "")
        let previous = try XCTUnwrap(model.dashboardEffectiveRecord)
        let previousFile = try XCTUnwrap(model.effectiveConfigTransaction.currentFile(previous))
        let previousData = try Data(contentsOf: previousFile)
        core.rejectValidation = true
        let secondApplied = await model.applyDashboardConfiguration(baseName: "Second.yaml", changes: [])
        XCTAssertFalse(secondApplied)
        XCTAssertEqual(model.selectedConfigName, "First.yaml")
        XCTAssertEqual(try model.effectiveConfigTransaction.currentRecord(), previous)
        XCTAssertEqual(try Data(contentsOf: previousFile), previousData)
        XCTAssertNotNil(model.dashboardConfigError)

        core.rejectValidation = false
        let subscription = RemoteConfigSubscription(urlString: "https://old.example/config", usage: SubscriptionUsage(upload: 1, download: 2, total: 10, expiresAt: nil))
        model.remoteConfigSubscriptions["First.yaml"] = subscription
        let invalid = await model.editDashboardSubscription(name: "First.yaml", newName: "Renamed", urlString: "https://")
        XCTAssertFalse(invalid)
        XCTAssertEqual(model.remoteConfigSubscriptions["First.yaml"], subscription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.configDirectoryURL.appendingPathComponent("First.yaml").path))
        let conflict = await model.editDashboardSubscription(name: "First.yaml", newName: "Second.yaml", urlString: "https://new.example/config")
        XCTAssertFalse(conflict)
        XCTAssertEqual(model.remoteConfigSubscriptions["First.yaml"], subscription)
        let renamed = await model.editDashboardSubscription(name: "First.yaml", newName: "Renamed", urlString: "https://new.example/config")
        XCTAssertTrue(renamed, model.dashboardConfigError ?? "")
        XCTAssertEqual(model.selectedConfigName, "Renamed.yaml")
        XCTAssertEqual(model.dashboardEffectiveRecord?.baseName, "Renamed.yaml")
        XCTAssertNil(model.remoteConfigSubscriptions["First.yaml"])
        XCTAssertEqual(model.remoteConfigSubscriptions["Renamed.yaml"]?.urlString, "https://new.example/config")
        XCTAssertEqual(model.remoteConfigSubscriptions["Renamed.yaml"]?.usage, subscription.usage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.configDirectoryURL.appendingPathComponent("First.yaml").path))

        let socketRoot = URL(fileURLWithPath: "/tmp/cb-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: socketRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: socketRoot) }
        let socket = AgentRuleSocket(stateDirectory: socketRoot) { request in
            await model.handleAgentRuleRequest(request)
        }
        try socket.start()
        defer { socket.stop() }
        let duplicate = AgentRuleSocket(stateDirectory: socketRoot) { _ in .failure("unexpected", "") }
        XCTAssertThrowsError(try duplicate.start())
        let socketPath = socketRoot.appendingPathComponent("agent/rules.sock").path
        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let initial = try await runAgentClient(socketPath, ["list"])
        let initialSnapshot = try XCTUnwrap(initial["snapshot"] as? [String: Any])
        let revision = try XCTUnwrap(initialSnapshot["revision"] as? String)
        XCTAssertEqual(initialSnapshot["baseName"] as? String, "Renamed.yaml")
        let added = try await runAgentClient(socketPath, ["add", "--revision", revision, "--operation", "add", "--value", "DOMAIN,agent.example,DIRECT"])
        XCTAssertEqual(added["ok"] as? Bool, true)
        let afterAdd = try XCTUnwrap(added["snapshot"] as? [String: Any])
        let nextRevision = try XCTUnwrap(afterAdd["revision"] as? String)
        let changes = try XCTUnwrap(afterAdd["changes"] as? [[String: Any]])
        let id = try XCTUnwrap(changes.first?["id"] as? String)
        XCTAssertEqual((afterAdd["effectiveRules"] as? [String])?.first, "DOMAIN,agent.example,DIRECT")

        let stale = try await runAgentClient(socketPath, ["remove", "--revision", revision, "--id", id])
        XCTAssertEqual(stale["code"] as? String, "conflict")
        core.rejectValidation = true
        let rejected = try await runAgentClient(socketPath, ["remove", "--revision", nextRevision, "--id", id])
        XCTAssertEqual(rejected["code"] as? String, "apply_failed")
        XCTAssertEqual(model.dashboardEffectiveRecord?.changes.count, 1)
        core.rejectValidation = false
        let updated = try await runAgentClient(socketPath, ["update", "--revision", nextRevision, "--id", id, "--operation", "add", "--value", "DOMAIN,other.example,REJECT"])
        let afterUpdate = try XCTUnwrap(updated["snapshot"] as? [String: Any])
        XCTAssertEqual((afterUpdate["effectiveRules"] as? [String])?.first, "DOMAIN,other.example,REJECT")
        let latestRevision = try XCTUnwrap(afterUpdate["revision"] as? String)
        let removed = try await runAgentClient(socketPath, ["remove", "--revision", latestRevision, "--id", id])
        XCTAssertEqual(removed["ok"] as? Bool, true)
        XCTAssertEqual(model.dashboardEffectiveRecord?.changes.count, 0)
    }

    private func runAgentClient(_ socketPath: String, _ arguments: [String]) async throws -> [String: Any] {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("skills/clashbar-rules/scripts/clashbar_rules.py").path
        let output = try await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script, "--socket", socketPath] + arguments
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value
        return try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
    }
}
