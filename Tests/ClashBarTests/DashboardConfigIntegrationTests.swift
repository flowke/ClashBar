import AppKit
import Foundation
import XCTest
@testable import ClashBar

private final class TestCore: MihomoControlling, @unchecked Sendable {
    var status: CoreLifecycleStatus { .stopped }
    var isRunning = false
    var binaryURL: URL?
    var detectedBinaryPath: String? {
        guard let binaryURL, FileManager.default.fileExists(atPath: binaryURL.path) else { return nil }
        return binaryURL.path
    }
    var rejectValidation = false
    var startCount = 0
    var stopCount = 0
    var startedPath: String?
    func validateConfigAsync(configPath: String) async throws {
        if rejectValidation { throw CocoaError(.fileReadCorruptFile) }
    }
    func startAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus {
        startCount += 1
        startedPath = configPath
        isRunning = true
        return .running(pid: 1)
    }
    func stop() {}
    func stopAsync() async { stopCount += 1; isRunning = false }
    func restartAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus { .stopped }
}

private final class PortRetryProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var port = 0
    nonisolated(unsafe) private static var attempts = 0
    nonisolated(unsafe) private static var releaseAfter = 2

    static func reset(releaseAfter: Int) {
        lock.withLock { port = 0; attempts = 0; self.releaseAfter = releaseAfter }
    }
    static var patchCount: Int { lock.withLock { attempts } }
    static var currentPort: Int { lock.withLock { port } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let data = Self.lock.withLock {
            if url.path == "/configs", method == "PATCH" {
                Self.attempts += 1
                if Self.attempts >= Self.releaseAfter { Self.port = 7890 }
            }
            return Data("{\"mixed-port\":\(Self.port)}".utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class DashboardConfigIntegrationTests: XCTestCase {
    func testPortRetryRecoversAndEditingCancelsPendingRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = WorkingDirectoryManager(homeDirectory: root)
        try directory.bootstrapDirectories()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PortRetryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let core = TestCore()
        core.isRunning = true
        let dependencies = AppDependencies(
            processManager: core,
            configService: ConfigService(configManager: ConfigDirectoryManager(workingDirectoryManager: directory), configImportService: ConfigImportService()),
            systemProxyService: SystemProxyService(), tunPermissionService: TunPermissionService(),
            launchAtLoginService: AppLaunchService(), workingDirectoryManager: directory,
            networkReachabilityMonitor: NetworkReachabilityMonitor(), ssidMonitorService: SSIDMonitorService(),
            remoteMachineStore: RemoteMachineStore(session: session),
            proxyGroupIconCache: ProxyGroupIconCache(iconDirectory: directory.iconDirectoryURL, session: session),
            webUIAssetService: WebUIAssetService(workingDirectoryManager: directory, session: session),
            clashbarLogStore: AppLogStore(logFileURL: directory.logsDirectoryURL.appendingPathComponent("clashbar.log")),
            mihomoLogStore: AppLogStore(logFileURL: directory.logsDirectoryURL.appendingPathComponent("mihomo.log")))
        let model = AppViewModel(dependencies: dependencies)
        defer { model.cancelOwnedTasks() }
        model.apiClient = MihomoAPIService(controller: "127.0.0.1:9090", secret: nil, session: session)
        let ports = ProxyPortValues(port: 0, socksPort: 0, mixedPort: 7890, redirPort: 0, tproxyPort: 0)
        PortRetryProtocol.reset(releaseAfter: 2)
        model.startProxyPortRetry(ports.patch, interval: 20_000_000)
        XCTAssertTrue(model.isRetryingProxyPorts)
        await model.proxyPortRetryTask?.value
        XCTAssertEqual(PortRetryProtocol.patchCount, 2)
        XCTAssertEqual(PortRetryProtocol.currentPort, 7890)
        XCTAssertNil(model.proxyPortWarning)
        XCTAssertFalse(model.isRetryingProxyPorts)

        PortRetryProtocol.reset(releaseAfter: 100)
        model.startProxyPortRetry(ports.patch, interval: 20_000_000)
        for _ in 0..<150 where PortRetryProtocol.patchCount == 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(PortRetryProtocol.patchCount, 1)
        model.scheduleProxyPortsAutoSaveIfNeeded()
        model.cancelProxyPortsAutoSave()
        await model.waitForProxyPortRetryToStop()
        XCTAssertEqual(PortRetryProtocol.patchCount, 1)
        XCTAssertFalse(model.isRetryingProxyPorts)
        XCTAssertNil(model.proxyPortWarning)

        PortRetryProtocol.reset(releaseAfter: 100)
        model.startProxyPortRetry(ports.patch, attempts: 2, interval: 20_000_000)
        await model.proxyPortRetryTask?.value
        XCTAssertEqual(PortRetryProtocol.patchCount, 2)
        XCTAssertFalse(model.isRetryingProxyPorts)
        XCTAssertNotNil(model.proxyPortWarning)
    }

    func testMissingCoreAutoStartReportsFailureWithoutModalWindow() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = WorkingDirectoryManager(homeDirectory: root)
        try directory.bootstrapDirectories()
        let session = URLSessionFactory.makeEphemeralSession(options: .init(timeoutIntervalForRequest: 15, timeoutIntervalForResource: 30))
        defer { session.invalidateAndCancel() }
        let core = TestCore()
        core.binaryURL = directory.managedMihomoBinaryURL
        let dependencies = AppDependencies(
            processManager: core,
            configService: ConfigService(configManager: ConfigDirectoryManager(workingDirectoryManager: directory), configImportService: ConfigImportService()),
            systemProxyService: SystemProxyService(), tunPermissionService: TunPermissionService(),
            launchAtLoginService: AppLaunchService(), workingDirectoryManager: directory,
            networkReachabilityMonitor: NetworkReachabilityMonitor(), ssidMonitorService: SSIDMonitorService(),
            remoteMachineStore: RemoteMachineStore(session: session),
            proxyGroupIconCache: ProxyGroupIconCache(iconDirectory: directory.iconDirectoryURL, session: session),
            webUIAssetService: WebUIAssetService(workingDirectoryManager: directory, session: session),
            clashbarLogStore: AppLogStore(logFileURL: directory.logsDirectoryURL.appendingPathComponent("clashbar.log")),
            mihomoLogStore: AppLogStore(logFileURL: directory.logsDirectoryURL.appendingPathComponent("mihomo.log")))
        let model = AppViewModel(dependencies: dependencies)

        await model.startCore(trigger: .auto)

        XCTAssertNil(NSApp.modalWindow)
        XCTAssertFalse(model.isMihomoCoreAvailable)
        XCTAssertTrue(model.isPrimaryCoreActionEnabled)
        XCTAssertNotNil(model.startupErrorMessage)
        XCTAssertEqual(model.statusItemBanner?.primaryDetail, model.startupErrorMessage)
        XCTAssertEqual(model.statusText, "Stopped")
        XCTAssertTrue(model.needsMihomoCoreInstallation)
        XCTAssertFalse(model.isSystemProxyToggleEnabled)
        await model.toggleSystemProxy(true)
        XCTAssertFalse(model.isSystemProxyEnabled)

        model.apiStatus = .healthy
        XCTAssertFalse(model.isSystemProxyToggleEnabled)
        core.isRunning = true
        XCTAssertTrue(model.isSystemProxyToggleEnabled)
        model.apiStatus = .degraded
        XCTAssertFalse(model.isSystemProxyToggleEnabled)
        model.apiStatus = .healthy
        model.coreActionState = .stopping
        XCTAssertFalse(model.isSystemProxyToggleEnabled)
        model.coreActionState = .idle
        model.isProxySyncing = true
        XCTAssertFalse(model.isSystemProxyToggleEnabled)
        model.isProxySyncing = false
        core.isRunning = false
        model.isSystemProxyEnabled = true
        XCTAssertTrue(model.isSystemProxyToggleEnabled)
        model.isSystemProxyEnabled = false

        let remote = RemoteMachine(name: "Test", host: "127.0.0.1")
        model.remoteMachineStore.machines = [remote]
        model.remoteMachineStore.activeTargetID = remote.id
        XCTAssertTrue(model.isSystemProxyToggleEnabled)
        model.apiStatus = .failed
        XCTAssertFalse(model.isSystemProxyToggleEnabled)
        model.remoteMachineStore.activeTargetID = nil
        model.apiStatus = .unknown

        model.startCoreDirectoryMonitoring()
        defer { model.cancelOwnedTasks() }
        try Data("test core".utf8).write(to: directory.managedMihomoBinaryURL)
        for _ in 0..<100 where !model.isMihomoCoreAvailable {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(model.isMihomoCoreAvailable)
        XCTAssertFalse(model.needsMihomoCoreInstallation)

        try FileManager.default.removeItem(at: directory.managedMihomoBinaryURL)
        for _ in 0..<100 where model.isMihomoCoreAvailable {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(model.isMihomoCoreAvailable)
        XCTAssertTrue(model.needsMihomoCoreInstallation)
    }

    func testManagedAlertSurvivesWindowSuppression() {
        _ = NSApplication.shared
        let delegate = ClashBarAppDelegate()
        let alert = NSAlert()
        let window = alert.window
        delegate.appViewModel.configureModalWindow(window)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        delegate.suppressWindowIfNeeded(window)

        XCTAssertTrue(window.isVisible)
    }

    func testManagedModalReturnsAfterApplicationActivation() {
        _ = NSApplication.shared
        let delegate = ClashBarAppDelegate()
        let alert = NSAlert()
        let input = NSTextField(string: "subscription input")
        alert.accessoryView = input
        let window = alert.window
        delegate.appViewModel.configureModalWindow(window)
        XCTAssertFalse(window.hidesOnDeactivate)

        let session = NSApp.beginModalSession(for: window)
        defer {
            NSApp.endModalSession(session)
            window.orderOut(nil)
        }
        _ = NSApp.runModalSession(session)
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)

        delegate.restoreManagedModalWindowIfNeeded()

        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(input.stringValue, "subscription input")
    }

    func testNonModalImportPromptCanBeRestoredAndCancelled() async {
        _ = NSApplication.shared
        let delegate = ClashBarAppDelegate()
        let alert = NSAlert()
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(string: "subscription input")
        alert.accessoryView = input
        delegate.appViewModel.configureModalWindow(alert.window)
        let presenter = NonModalAlertPresenter(alert: alert)
        let task = Task { await presenter.present() }
        await Task.yield()

        XCTAssertTrue(alert.window.isVisible)
        XCTAssertNil(NSApp.modalWindow)
        alert.window.orderOut(nil)
        presenter.show()
        XCTAssertTrue(alert.window.isVisible)
        XCTAssertEqual(input.stringValue, "subscription input")
        alert.buttons[1].performClick(nil)
        let response = await task.value
        XCTAssertEqual(response, .alertSecondButtonReturn)
        XCTAssertFalse(alert.window.isVisible)
        XCTAssertNil(NSApp.modalWindow)
    }

    func testClosingNonModalImportPromptCancelsIt() async {
        _ = NSApplication.shared
        let alert = NSAlert()
        alert.addButton(withTitle: "Import")
        let presenter = NonModalAlertPresenter(alert: alert)
        let task = Task { await presenter.present() }
        await Task.yield()

        alert.window.close()
        let response = await task.value
        XCTAssertEqual(response, .cancel)
        XCTAssertNil(NSApp.modalWindow)
    }

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
        let manualPortsKey = "clashbar.settings.proxyPorts.manual.v1"
        let savedManualPorts = UserDefaults.standard.object(forKey: manualPortsKey)
        defer {
            if let savedManualPorts { UserDefaults.standard.set(savedManualPorts, forKey: manualPortsKey) }
            else { UserDefaults.standard.removeObject(forKey: manualPortsKey) }
        }
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
        XCTAssertEqual(try model.resolvedProxyPorts().mixedPort, 7890)
        let manual = ProxyPortValues(port: 0, socksPort: 0, mixedPort: 8888, redirPort: 0, tproxyPort: 0)
        model.settingsPort = "0"
        model.settingsSocksPort = "0"
        model.settingsMixedPort = "8888"
        model.settingsRedirPort = "0"
        model.settingsTProxyPort = "0"
        await model.applyProxyPorts()
        XCTAssertEqual(model.manualProxyPorts, manual)
        XCTAssertEqual(model.decodeFromDefaults(ProxyPortValues.self, key: manualPortsKey), manual)
        XCTAssertEqual(try model.resolvedProxyPorts(), manual)
        await model.followConfigProxyPorts()
        XCTAssertNil(model.manualProxyPorts)
        XCTAssertNil(model.decodeFromDefaults(ProxyPortValues.self, key: manualPortsKey))
        XCTAssertEqual(model.settingsMixedPort, "7890")
        XCTAssertEqual(try model.resolvedProxyPorts().mixedPort, 7890)
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
        try Data("mixed-port: 9091\nrules: ['MATCH,DIRECT']".utf8)
            .write(to: directory.configDirectoryURL.appendingPathComponent("Second.yaml"))
        model.manualProxyPorts = manual
        let secondURL = directory.configDirectoryURL.appendingPathComponent("Second.yaml")
        XCTAssertEqual(try model.resolvedProxyPorts(configURL: secondURL).mixedPort, 8888)
        model.manualProxyPorts = nil
        XCTAssertEqual(try model.resolvedProxyPorts(configURL: secondURL).mixedPort, 9091)
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

        let intervalUpdated = await model.editDashboardSubscription(
            name: "Renamed.yaml",
            newName: "Renamed.yaml",
            urlString: "https://new.example/config",
            autoUpdateEnabled: true,
            autoUpdateIntervalHours: 0)
        XCTAssertTrue(intervalUpdated, model.dashboardConfigError ?? "")
        XCTAssertTrue(model.remoteConfigSubscriptions["Renamed.yaml"]?.autoUpdateEnabled == true)
        XCTAssertEqual(model.remoteConfigSubscriptions["Renamed.yaml"]?.autoUpdateIntervalHours, 1)

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

        let retainedChange = CustomRuleChange(operation: .add, original: "", value: "DOMAIN,retained.example,DIRECT")
        let updatedConfig = await model.applyDashboardConfiguration(baseName: "Renamed.yaml", changes: [retainedChange])
        XCTAssertTrue(updatedConfig)
        core.isRunning = true
        await model.deleteDashboardConfig("Renamed.yaml", confirmed: true)
        XCTAssertFalse(core.isRunning)
        XCTAssertEqual(core.stopCount, 1)
        XCTAssertEqual(model.selectedConfigName, "-")
        XCTAssertNil(service.selectedConfig)
        XCTAssertNil(model.remoteConfigSubscriptions["Renamed.yaml"])
        XCTAssertEqual(try model.effectiveConfigTransaction.currentRecord()?.changes, [retainedChange])
        _ = service.reloadConfigs()
        model.syncConfigDisplayState()
        XCTAssertEqual(model.selectedConfigName, "-")
        XCTAssertNil(service.selectedConfig)
        model.restoreSavedConfigDirectory()
        model.restoreLastSuccessfulConfigIfAvailable()
        XCTAssertNil(service.selectedConfig)
        let unselectedPath = await model.resolveSelectedConfigPath()
        XCTAssertNil(unselectedPath)

        try Data("test core".utf8).write(to: directory.managedMihomoBinaryURL)
        core.binaryURL = directory.managedMihomoBinaryURL
        await model.selectDashboardConfiguration("Second.yaml", changes: [retainedChange])
        XCTAssertEqual(core.startCount, 1)
        XCTAssertTrue(core.isRunning)
        XCTAssertEqual(model.selectedConfigName, "Second.yaml")
        XCTAssertEqual(model.dashboardEffectiveRecord?.changes, [retainedChange])
        XCTAssertEqual(core.startedPath, model.effectiveConfigURL(for: "Second.yaml")?.path)
        model.cancelOwnedTasks()
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

final class PanelGeometryTests: XCTestCase {
    func testMenuBarDropdownPlacementStaysOnTheAnchoredDisplay() {
        let panelSize = CGSize(width: 432, height: 336)
        let options = MenuBarDropdownPlacementOptions(
            horizontalPadding: 10,
            verticalSpacing: 6,
            screenPadding: 10,
            lockedOriginX: nil,
            preserveHorizontalPosition: false)
        let displays: [(CGRect, CGRect)] = [
            (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 870, width: 24, height: 24)),
            (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1416, y: 870, width: 24, height: 24)),
            (CGRect(x: 1440, y: -80, width: 1280, height: 800), CGRect(x: 2696, y: 690, width: 24, height: 24)),
        ]

        for (visibleFrame, anchorFrame) in displays {
            let context = PanelAnchorContext(
                visibleFrame: visibleFrame,
                anchorFrameOnScreen: anchorFrame,
                hostWindowFrame: nil)
            let frame = context.menuBarDropdownPlacement(panelSize: panelSize, options: options).frame

            XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX + options.screenPadding)
            XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX - options.screenPadding)
            XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY + options.screenPadding)
            XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY)
        }
    }

    func testDashboardPlacementCentersOnWindowAndClampsToVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panelSize = CGSize(width: 432, height: 336)
        let centeredContext = PanelAnchorContext(
            visibleFrame: visibleFrame,
            anchorFrameOnScreen: CGRect(x: 220, y: 100, width: 1000, height: 700),
            hostWindowFrame: CGRect(x: 220, y: 100, width: 1000, height: 700))
        let centered = centeredContext.centeredWindowPlacement(panelSize: panelSize, screenPadding: 16).frame

        XCTAssertEqual(centered.midX, 720, accuracy: 0.5)
        XCTAssertEqual(centered.midY, 450, accuracy: 0.5)

        let edgeContext = PanelAnchorContext(
            visibleFrame: visibleFrame,
            anchorFrameOnScreen: CGRect(x: -200, y: -80, width: 500, height: 360),
            hostWindowFrame: CGRect(x: -200, y: -80, width: 500, height: 360))
        let clamped = edgeContext.centeredWindowPlacement(panelSize: panelSize, screenPadding: 16).frame

        XCTAssertEqual(clamped.minX, 16, accuracy: 0.5)
        XCTAssertEqual(clamped.minY, 16, accuracy: 0.5)
        XCTAssertLessThanOrEqual(clamped.maxX, visibleFrame.maxX - 16)
        XCTAssertLessThanOrEqual(clamped.maxY, visibleFrame.maxY - 16)
    }
}
