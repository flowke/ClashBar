import AppKit
import SwiftUI
import XCTest
@testable import ClashBar

@MainActor
final class ServiceStatusRenderingTests: XCTestCase {
    func testHidingRetainedWindowCancelsChecks() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clashbar-status-visibility-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(root: root)
        let model = app.serviceStatusStore
        model.observe(app: app)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: DashboardServiceStatusView(appViewModel: app, model: model))
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        window.contentView?.layoutSubtreeIfNeeded()
        model.start(checker: RenderingServiceChecker())
        try await waitUntil { model.activeServiceName != nil }
        app.isDashboardPresented = false
        try await waitUntil { !model.isRunning }
        XCTAssertNotNil(window.contentView, "The real dashboard retains its hosting view when closed")
        XCTAssertEqual(model.results[ServiceEndpoint.builtIns[0].id]?.current.state, .cancelled)
        model.start(checker: CompletedServiceChecker())
        try await waitUntil { !model.isRunning }
        // Closing a dashboard clears its rule cache without changing the core.
        app.ruleItems = try JSONDecoder().decode([RuleItem].self, from: Data("[{\"type\":\"Match\",\"proxy\":\"DIRECT\"}]".utf8))
        app.isDashboardPresented = true
        app.setDashboardVisibility(false)
        await Task.yield()
        XCTAssertFalse(model.hasStaleResults)
    }

    func testServiceStatusStatesAndNarrowWindow() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clashbar-status-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(root: root)
        let model = app.serviceStatusStore
        try render("initial", width: 1100, view: DashboardView(appViewModel: app, initialPage: .serviceStatus))

        model.start(checker: CompletedServiceChecker())
        try await waitUntil { !model.isRunning }
        try render("results", width: 1100, view: DashboardView(appViewModel: app, initialPage: .serviceStatus))
        model.invalidate()
        try render("stale", width: 1100, view: DashboardView(appViewModel: app, initialPage: .serviceStatus))

        try render("add", width: 880, view: ScrollView {
            DashboardServiceStatusView(appViewModel: app, model: model, initiallyAdding: true).padding(32)
        }.background(.white))
        try model.add(name: "A company with a very long service name", url: "https://example.com/full/path/with/a/long/name?query=retained&source=service-status")
        try render("custom", width: 1240, view: DashboardView(appViewModel: app, initialPage: .serviceStatus))
        try render("narrow", width: 760, view: DashboardView(appViewModel: app, initialPage: .serviceStatus))
        model.start(checker: RenderingServiceChecker())
        try await waitUntil { model.activeServiceName != nil }
        try render("running", width: 1100, view: DashboardView(appViewModel: app, initialPage: .serviceStatus))
        // Removing the page must cancel outstanding measurements.
        try await waitUntil { !model.isRunning }
        XCTAssertEqual(model.results[ServiceEndpoint.builtIns[0].id]?.current.state, .cancelled)
    }

    private func render<V: View>(_ name: String, width: CGFloat, view: V) throws {
        let window = DashboardWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                                     styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let controller = NSHostingController(rootView: view.environment(\.colorScheme, .light))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.configureTitlebar()
        window.setContentSize(NSSize(width: width, height: 800))
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentViewController = nil }
        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertEqual(host.bounds.width, width, accuracy: 1)
        XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        if let directory = ProcessInfo.processInfo.environment["CLASHBAR_SERVICE_SCREENSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Service status did not settle")
    }

    private func makeApp(root: URL) throws -> AppViewModel {
        let directory = WorkingDirectoryManager(homeDirectory: root)
        try directory.bootstrapDirectories()
        let session = URLSessionFactory.makeEphemeralSession(options: .init(timeoutIntervalForRequest: 2, timeoutIntervalForResource: 2))
        let config = ConfigService(configManager: ConfigDirectoryManager(workingDirectoryManager: directory), configImportService: ConfigImportService())
        config.setConfigDirectory(directory.configDirectoryURL)
        let app = AppViewModel(dependencies: AppDependencies(
            processManager: MihomoProcessManager(workingDirectoryManager: directory), configService: config,
            systemProxyService: SystemProxyService(), tunPermissionService: TunPermissionService(),
            launchAtLoginService: AppLaunchService(), workingDirectoryManager: directory,
            networkReachabilityMonitor: NetworkReachabilityMonitor(), ssidMonitorService: SSIDMonitorService(),
            remoteMachineStore: RemoteMachineStore(session: session),
            proxyGroupIconCache: ProxyGroupIconCache(iconDirectory: directory.iconDirectoryURL, session: session),
            webUIAssetService: WebUIAssetService(workingDirectoryManager: directory, session: session),
            clashbarLogStore: AppLogStore(logFileURL: directory.logsDirectoryURL.appendingPathComponent("clashbar.log")),
            mihomoLogStore: AppLogStore(logFileURL: directory.logsDirectoryURL.appendingPathComponent("mihomo.log"))))
        app.uiLanguage = .zhHans
        app.isDashboardPresented = true
        return app
    }
}

private actor RenderingServiceChecker: ServiceStatusChecking {
    func prepare() async throws {}
    func measure(_ endpoint: ServiceEndpoint, kind: ServiceProbeKind) async throws -> ServiceProbeResult {
        try await Task.sleep(for: .seconds(30))
        return ServiceProbeResult(state: .reachable)
    }
    func close() async {}
}
