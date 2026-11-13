import AppKit
import ProxyHelperShared
import SwiftUI
import XCTest
@testable import ClashBar

private let expectedProxy = SystemProxyTarget(
    host: "127.0.0.1", ports: SystemProxyPorts(httpPort: 7890, httpsPort: 7890, socksPort: 7890))

private func proxyConfiguration(port: Int = 7890, host: String = "127.0.0.1",
                                https: Bool = true, automatic: Bool = false) -> SystemProxySnapshot.Configuration {
    SystemProxySnapshot.Configuration(dictionary: [
        "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
        "HTTPSEnable": https ? 1 : 0, "HTTPSProxy": host, "HTTPSPort": port,
        "SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": port,
        "ProxyAutoConfigEnable": automatic ? 1 : 0,
    ])
}

private final class ProxyStateService: SystemProxyServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = SystemProxySnapshot(configurations: [proxyConfiguration()])
    private var failRead = false
    private var failApply = false
    private var mutations: [Bool] = []
    private var reads = 0
    var writes: [Bool] { self.lock.withLock { self.mutations } }
    var readCount: Int { self.lock.withLock { self.reads } }

    func set(_ configurations: [SystemProxySnapshot.Configuration], unreadable: Bool = false, rejectApply: Bool = false) {
        self.lock.withLock {
            self.snapshot = SystemProxySnapshot(configurations: configurations)
            self.failRead = unreadable
            self.failApply = rejectApply
        }
    }

    func readSnapshot() throws -> SystemProxySnapshot {
        try self.lock.withLock {
            self.reads += 1
            if self.failRead { throw SystemProxyServiceError.configurationUnavailable }
            return self.snapshot
        }
    }

    func apply(enabled: Bool, host: String, ports: SystemProxyPorts) async throws {
        try self.lock.withLock {
            self.mutations.append(enabled)
            if self.failApply { throw SystemProxyServiceError.helperOperationFailed("Rejected") }
            self.snapshot = SystemProxySnapshot(configurations: [
                enabled ? proxyConfiguration(port: ports.primaryPort ?? 0, host: host) : .init(dictionary: [:]),
            ])
        }
    }

    func isEnabled() async throws -> Bool { try self.readSnapshot().isEnabled }
    func readActiveDisplay() async throws -> String? { try self.readSnapshot().activeDisplays.first }
    func readExceptionsList() async throws -> [String] { [] }
    func setExceptionsList(_ exceptions: [String]) async throws {}
    func installOrUpdateHelper() async throws {}
    func readHelperHealthSnapshot() async -> SystemProxyHelperHealthSnapshot {
        .init(helperInstalled: true, processRunning: true, installedVersion: ProxyHelperConstants.helperVersion,
              expectedVersion: ProxyHelperConstants.helperVersion, failureReason: nil, rawMessage: nil)
    }
    func isConfigured(host: String, ports: SystemProxyPorts) async throws -> Bool {
        try self.readSnapshot().matches(.init(host: host, ports: ports))
    }
    func clearBlocking(timeout: TimeInterval) { self.lock.withLock { self.mutations.append(false) } }
}

private final class ProxyStateCore: MihomoControlling, @unchecked Sendable {
    var status: CoreLifecycleStatus { self.isRunning ? .running(pid: 1) : .stopped }
    var isRunning = true
    var detectedBinaryPath: String? { nil }
    func validateConfigAsync(configPath: String) async throws {}
    func startAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus { self.status }
    func stop() { self.isRunning = false }
    func stopAsync() async { self.stop() }
    func restartAsync(configPath: String, controller: String) async throws -> CoreLifecycleStatus { self.status }
}

private final class ProxyStateAPI: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let port = Int(self.request.value(forHTTPHeaderField: "X-Test-Mixed-Port") ?? "") ?? 7890
        self.client?.urlProtocol(self, didLoad: Data("{\"mixed-port\":\(port)}".utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class ProxyStateFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = ProxyStateService()
    let core = ProxyStateCore()
    let session: URLSession
    let model: AppViewModel
    private let persisted: [String: Any]
    private let keys = ["clashbar.system_proxy.expected_target.v1", "clashbar.system_proxy.enabled_on_quit",
                        "clashbar.system_proxy.resume_after_owned_clear"]

    init(runtimePort: Int = 7890) throws {
        self.persisted = Dictionary(uniqueKeysWithValues: self.keys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
        let directory = WorkingDirectoryManager(homeDirectory: self.root)
        try directory.bootstrapDirectories()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyStateAPI.self]
        configuration.httpAdditionalHeaders = ["X-Test-Mixed-Port": String(runtimePort)]
        self.session = URLSession(configuration: configuration)
        let config = ConfigService(configManager: ConfigDirectoryManager(workingDirectoryManager: directory),
                                   configImportService: ConfigImportService())
        self.model = AppViewModel(dependencies: AppDependencies(
            processManager: self.core, configService: config, systemProxyService: self.service,
            tunPermissionService: TunPermissionService(), launchAtLoginService: AppLaunchService(),
            workingDirectoryManager: directory, networkReachabilityMonitor: NetworkReachabilityMonitor(),
            ssidMonitorService: SSIDMonitorService(), remoteMachineStore: RemoteMachineStore(session: self.session),
            proxyGroupIconCache: ProxyGroupIconCache(iconDirectory: directory.iconDirectoryURL, session: self.session),
            webUIAssetService: WebUIAssetService(workingDirectoryManager: directory, session: self.session),
            clashbarLogStore: AppLogStore(logFileURL: directory.logsDirectoryURL.appendingPathComponent("clashbar.log")),
            mihomoLogStore: AppLogStore(logFileURL: directory.logsDirectoryURL.appendingPathComponent("mihomo.log"))))
        self.model.apiClient = MihomoAPIService(controller: "127.0.0.1:9090", secret: nil, session: self.session)
        self.model.statusText = "Running"
        self.model.apiStatus = .healthy
        self.model.mixedPort = runtimePort
        self.model.isSystemProxyEnabled = true
        self.model.systemProxyExpectedTarget = expectedProxy
    }

    func cleanup() {
        self.model.cancelOwnedTasks()
        self.session.invalidateAndCancel()
        for key in self.keys {
            if let value = self.persisted[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: self.root)
    }
}

@MainActor
final class SystemProxyStateTests: XCTestCase {
    func testSnapshotComparesEveryProtocolAndServiceIncludingPAC() {
        XCTAssertTrue(SystemProxySnapshot(configurations: [proxyConfiguration(host: "localhost")]).matches(expectedProxy))
        XCTAssertFalse(SystemProxySnapshot(configurations: [proxyConfiguration(host: "::1")]).matches(expectedProxy))
        XCTAssertFalse(SystemProxySnapshot(configurations: [proxyConfiguration(port: 8888)]).matches(expectedProxy))
        XCTAssertFalse(SystemProxySnapshot(configurations: [proxyConfiguration(https: false)]).matches(expectedProxy))
        XCTAssertFalse(SystemProxySnapshot(configurations: [proxyConfiguration(automatic: true)]).matches(expectedProxy))
        XCTAssertFalse(SystemProxySnapshot(configurations: [proxyConfiguration(), proxyConfiguration(port: 8888)]).matches(expectedProxy))
        XCTAssertFalse(SystemProxySnapshot(configurations: [.init(dictionary: [:])]).matches(expectedProxy))
        XCTAssertFalse(SystemProxySnapshot(configurations: []).matches(expectedProxy))
    }

    func testExternalChangesPreserveIntentWithoutWritingAndCanRecoverNaturally() async throws {
        let fixture = try ProxyStateFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        await model.refreshSystemProxyStatus()
        XCTAssertEqual(model.systemProxyStatus, .active)
        fixture.service.set([proxyConfiguration(port: 8888)])
        await model.refreshSystemProxyStatus()
        XCTAssertTrue(model.isSystemProxyEnabled)
        XCTAssertEqual(model.systemProxyStatus, .overridden)
        XCTAssertTrue(model.systemProxyToggleTarget)
        XCTAssertEqual(model.runtimeVisualStatus, .runningDegraded)
        XCTAssertTrue(model.menuBarDisplaySnapshot.hasWarning)
        XCTAssertTrue(model.systemProxyStatusHelp.contains("8888"))
        fixture.service.set([.init(dictionary: [:])])
        await model.refreshSystemProxyStatus()
        XCTAssertEqual(model.systemProxyStatus, .overridden)
        fixture.service.set([], unreadable: true)
        await model.refreshSystemProxyStatus()
        XCTAssertEqual(model.systemProxyStatus, .unknown)
        fixture.service.set([proxyConfiguration()])
        await model.refreshSystemProxyStatus()
        XCTAssertEqual(model.systemProxyStatus, .active)
        XCTAssertFalse(model.menuBarDisplaySnapshot.hasWarning)
        XCTAssertTrue(fixture.service.writes.isEmpty)
    }

    func testExplicitRestoreWritesThenVerifiesActualConfiguration() async throws {
        let fixture = try ProxyStateFixture()
        defer { fixture.cleanup() }
        fixture.service.set([proxyConfiguration(port: 8888, automatic: true)])
        fixture.model.checkSystemProxyConfiguration()
        await fixture.model.toggleSystemProxy(fixture.model.systemProxyToggleTarget)
        XCTAssertEqual(fixture.service.writes, [true])
        XCTAssertEqual(fixture.model.systemProxyStatus, .active)
        XCTAssertTrue(fixture.model.isSystemProxyEnabled)
        XCTAssertEqual(fixture.model.systemProxyExpectedTarget, expectedProxy)
    }

    func testFailedRestoreKeepsConflictVisible() async throws {
        let fixture = try ProxyStateFixture()
        defer { fixture.cleanup() }
        fixture.service.set([proxyConfiguration(port: 8888)], rejectApply: true)
        fixture.model.systemProxyStatus = .active
        await fixture.model.toggleSystemProxy(true)
        XCTAssertEqual(fixture.model.systemProxyStatus, .overridden)
        XCTAssertTrue(fixture.model.isSystemProxyEnabled)
        XCTAssertEqual(fixture.model.systemProxyActualDisplay, "127.0.0.1:8888")
    }

    func testStartupRecoveryAndPortSyncDoNotReclaimExternalProxy() async throws {
        let fixture = try ProxyStateFixture()
        defer { fixture.cleanup() }
        fixture.service.set([proxyConfiguration(port: 8888)])
        await fixture.model.ensureSystemProxyConsistencyOnFirstLaunchIfNeeded()
        fixture.model.pendingCoreFeatureRecoveryState = .init(systemProxyEnabled: true, tunEnabled: false)
        await fixture.model.restoreCoreFeaturesAfterStartupIfNeeded()
        await fixture.model.syncSystemProxyPortIfNeeded(shouldSync: true, previousPorts: expectedProxy.ports)
        XCTAssertEqual(fixture.model.systemProxyStatus, .overridden)
        XCTAssertNil(fixture.model.pendingCoreFeatureRecoveryState)
        XCTAssertTrue(fixture.service.writes.isEmpty)
    }

    func testRecoveryResumesOwnedClearOnlyWhenNoExternalProxyIsPresent() async throws {
        for externalProxy in [false, true] {
            let fixture = try ProxyStateFixture(runtimePort: 7891)
            defer { fixture.cleanup() }
            fixture.service.set([externalProxy ? proxyConfiguration(port: 8888) : .init(dictionary: [:])])
            fixture.model.isSystemProxyEnabled = false
            fixture.model.systemProxyMayResumeAfterOwnedClear = true
            fixture.model.pendingCoreFeatureRecoveryState = .init(systemProxyEnabled: true, tunEnabled: false)
            await fixture.model.restoreCoreFeaturesAfterStartupIfNeeded()
            XCTAssertEqual(fixture.service.writes, externalProxy ? [] : [true])
            XCTAssertEqual(fixture.model.systemProxyStatus, externalProxy ? .overridden : .active)
            XCTAssertEqual(fixture.model.systemProxyExpectedTarget?.ports.primaryPort, 7891)
        }
    }

    func testExplicitDisableAndOwnedQuitRetainNormalCleanup() async throws {
        let fixture = try ProxyStateFixture()
        defer { fixture.cleanup() }
        await fixture.model.toggleSystemProxy(false)
        XCTAssertEqual(fixture.service.writes, [false])
        XCTAssertFalse(fixture.model.isSystemProxyEnabled)
        XCTAssertEqual(fixture.model.systemProxyStatus, .disabled)
        fixture.service.set([proxyConfiguration()])
        fixture.model.isSystemProxyEnabled = true
        fixture.model.shutdownForTermination()
        XCTAssertEqual(fixture.service.writes, [false, false])
    }

    func testResetSystemProxyObservedStatePreservesHelperHealth() throws {
        let fixture = try ProxyStateFixture()
        defer { fixture.cleanup() }
        fixture.model.systemProxyHelperInstalled = true
        fixture.model.systemProxyHelperProcessRunning = true
        fixture.model.systemProxyHelperInstalledVersion = ProxyHelperConstants.helperVersion
        fixture.model.systemProxyHelperExpectedVersion = ProxyHelperConstants.helperVersion
        fixture.model.isSystemProxyEnabled = false

        fixture.model.resetSystemProxyObservedState()

        XCTAssertTrue(fixture.model.systemProxyHelperInstalled == true)
        XCTAssertTrue(fixture.model.systemProxyHelperProcessRunning == true)
        XCTAssertEqual(fixture.model.systemProxyHelperInstalledVersion, ProxyHelperConstants.helperVersion)
        XCTAssertEqual(fixture.model.systemProxyHelperExpectedVersion, ProxyHelperConstants.helperVersion)
    }

    func testStopAndQuitLeaveExternalProxyUntouched() async throws {
        let fixture = try ProxyStateFixture()
        defer { fixture.cleanup() }
        fixture.service.set([proxyConfiguration(port: 8888)])
        // The UI has not observed the change yet: transitions must re-read before clearing.
        fixture.model.systemProxyStatus = .active
        await fixture.model.stopCore()
        XCTAssertTrue(fixture.service.writes.isEmpty)
        XCTAssertTrue(fixture.model.isSystemProxyEnabled)
        fixture.model.shutdownForTermination()
        XCTAssertTrue(fixture.service.writes.isEmpty)
    }

    func testBackgroundMonitorWorksWithPanelClosedAndCleansUp() async throws {
        let fixture = try ProxyStateFixture()
        defer { fixture.cleanup() }
        fixture.service.set([proxyConfiguration(port: 8888)])
        fixture.model.startSystemProxyMonitoring()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(fixture.model.isPanelPresented)
        XCTAssertEqual(fixture.model.systemProxyStatus, .overridden)
        fixture.service.set([proxyConfiguration()])
        // No notification is delivered: the independent fallback must still notice the change.
        try await Task.sleep(nanoseconds: 3_150_000_000)
        XCTAssertEqual(fixture.model.systemProxyStatus, .active)
        fixture.model.stopSystemProxyMonitoring()
        XCTAssertNil(fixture.model.systemProxyMonitorTask)
        XCTAssertNil(fixture.model.systemProxyDebounceTask)
        XCTAssertTrue(fixture.service.writes.isEmpty)
    }

    func testHeaderIconTracksAllStatesWithoutReopeningInBothThemes() async throws {
        let fixture = try ProxyStateFixture()
        defer { fixture.cleanup() }
        _ = NSApplication.shared
        let states: [(Bool, Bool, Bool, Bool, MenuBarIconState)] = [
            (false, false, false, false, .sleep),
            (true, true, false, false, .run),
            (true, false, true, false, .tun),
            (true, false, true, true, .warning),
            (true, true, false, false, .run),
            (true, false, false, false, .sleep),
        ]
        for dark in [false, true] {
            let view = MenuBarHeaderView(showRemoteMachineManager: .constant(false), isSwitchingMachine: .constant(false))
                .environmentObject(fixture.model)
                .environmentObject(fixture.model.remoteMachineStore)
                .frame(width: 350, height: 56)
                .background(dark ? Color.black : .white)
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 350, height: 56),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            var runningIcon: Data?
            for (running, proxy, tun, warning, expected) in states {
                fixture.core.isRunning = running
                fixture.model.statusText = running ? "Running" : "Stopped"
                fixture.model.isSystemProxyEnabled = proxy
                fixture.model.isTunEnabled = tun
                fixture.model.apiStatus = warning ? .degraded : .healthy
                XCTAssertEqual(fixture.model.menuBarDisplaySnapshot.iconState, expected)
                try await Task.sleep(for: .milliseconds(30))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
                let image = try XCTUnwrap(bitmap.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: 40 * scale, height: 56 * scale)))
                let icon = NSBitmapImageRep(cgImage: image)
                var green = 0
                var yellow = 0
                var foreground = 0
                for row in 0..<icon.pixelsHigh {
                    for column in 0..<icon.pixelsWide {
                        let color = try XCTUnwrap(icon.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB))
                        if color.greenComponent > color.redComponent + 0.15, color.greenComponent > color.blueComponent + 0.08 {
                            green += 1
                        }
                        if color.redComponent > color.greenComponent + 0.15, color.greenComponent > color.blueComponent + 0.25 {
                            yellow += 1
                        }
                        if dark ? color.redComponent > 0.5 : color.redComponent < 0.5 { foreground += 1 }
                    }
                }
                let data = try XCTUnwrap(icon.representation(using: .png, properties: [:]))
                switch expected {
                case .sleep:
                    XCTAssertEqual(green, 0)
                    XCTAssertEqual(yellow, 0)
                    XCTAssertGreaterThan(foreground, 50, "The outline must stay visible in either theme")
                case .run, .tun:
                    XCTAssertGreaterThan(green, 100)
                    XCTAssertEqual(yellow, 0)
                    if expected == .run { runningIcon = data }
                    else { XCTAssertNotEqual(data, runningIcon, "TUN must show a shield instead of the running icon") }
                case .warning:
                    XCTAssertGreaterThan(yellow, 50)
                    XCTAssertEqual(green, 0)
                }
                if let path = ProcessInfo.processInfo.environment["CLASHBAR_HEADER_PREVIEW_DIR"] {
                    let directory = URL(fileURLWithPath: path)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: directory.appendingPathComponent("header-\(dark ? "dark" : "light")-\(expected).png"))
                }
            }
        }
    }

    func testWarningSwitchAndHeaderRenderWithinCompactPanelInBothThemes() throws {
        let fixture = try ProxyStateFixture()
        defer { fixture.cleanup() }
        _ = NSApplication.shared
        fixture.service.set([proxyConfiguration(port: 8888)])
        fixture.model.checkSystemProxyConfiguration()
        for dark in [false, true] {
            let view = VStack(spacing: 8) {
                MenuBarHeaderView(showRemoteMachineManager: .constant(false), isSwitchingMachine: .constant(false))
                ProxyTabView(rootViewModel: ProxyGroupsViewModel())
            }
            .environmentObject(fixture.model)
            .environmentObject(fixture.model.remoteMachineStore)
            .environmentObject(fixture.model.proxyStore)
            .environmentObject(fixture.model.trafficStore)
            .environmentObject(fixture.model.connectionsStore)
            .padding(8).frame(width: 350)
            .background(dark ? Color(nsColor: .windowBackgroundColor) : .white)
            .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 350, height: 500),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, 351)
            if let path = ProcessInfo.processInfo.environment["CLASHBAR_PROXY_SCREENSHOT_DIR"] {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: path).appendingPathComponent(dark ? "proxy-dark.png" : "proxy-light.png"))
            }
        }
    }
}
