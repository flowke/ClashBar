import AppKit
import SwiftUI
import XCTest
@testable import ClashBar

private final class WebUIUpdateProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [WebUIUpdateProtocol] = []
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int { self.lock.withLock { self.count } }
    static var hasPendingRequest: Bool { self.lock.withLock { !self.pending.isEmpty } }

    static func reset() {
        self.lock.withLock { self.pending = []; self.count = 0 }
    }

    static func complete(version: String = "1.0.0", statusCode: Int = 200) {
        let requests = self.lock.withLock {
            let requests = self.pending
            self.pending = []
            return requests
        }
        for request in requests {
            let response = HTTPURLResponse(url: request.request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            let data = Data("{\"tag_name\":\"v\(version)\",\"draft\":false,\"prerelease\":false,\"assets\":[]}".utf8)
            request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
            request.client?.urlProtocol(request, didLoad: data)
            request.client?.urlProtocolDidFinishLoading(request)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.pending.append(self); Self.count += 1 }
    }
    override func stopLoading() {
        Self.lock.withLock { Self.pending.removeAll { $0 === self } }
    }
}

@MainActor
final class WebUIUpdateFeedbackTests: XCTestCase {
    private var root: URL!
    private var session: URLSession!
    private var app: AppViewModel!

    override func setUp() async throws {
        try await super.setUp()
        WebUIUpdateProtocol.reset()
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("clashbar-webui-feedback-\(UUID().uuidString)")
        let directory = WorkingDirectoryManager(homeDirectory: self.root)
        try directory.bootstrapDirectories()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebUIUpdateProtocol.self]
        self.session = URLSession(configuration: configuration)
        let webUI = WebUIAssetService(workingDirectoryManager: directory, session: self.session)
        let assets = webUI.currentDirectoryURL(for: .metaCubeXD)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data("<html>Installed WebUI</html>".utf8).write(to: assets.appendingPathComponent("index.html"))
        let metadata = try JSONSerialization.data(withJSONObject: ["currentVersion": "1.0.0"])
        try metadata.write(to: webUI.rootDirectoryURL.appendingPathComponent(".metacubexd-metadata.json"))
        let config = ConfigService(configManager: ConfigDirectoryManager(workingDirectoryManager: directory), configImportService: ConfigImportService())
        config.setConfigDirectory(directory.configDirectoryURL)
        self.app = AppViewModel(dependencies: AppDependencies(
            processManager: MihomoProcessManager(workingDirectoryManager: directory), configService: config,
            systemProxyService: SystemProxyService(), tunPermissionService: TunPermissionService(),
            launchAtLoginService: AppLaunchService(), workingDirectoryManager: directory,
            networkReachabilityMonitor: NetworkReachabilityMonitor(), ssidMonitorService: SSIDMonitorService(),
            remoteMachineStore: RemoteMachineStore(session: self.session),
            proxyGroupIconCache: ProxyGroupIconCache(iconDirectory: directory.iconDirectoryURL, session: self.session),
            webUIAssetService: webUI,
            clashbarLogStore: AppLogStore(logFileURL: directory.logsDirectoryURL.appendingPathComponent("clashbar.log")),
            mihomoLogStore: AppLogStore(logFileURL: directory.logsDirectoryURL.appendingPathComponent("mihomo.log"))))
    }

    override func tearDown() async throws {
        self.app.cancelOwnedTasks()
        self.session.invalidateAndCancel()
        self.app = nil
        self.session = nil
        try? FileManager.default.removeItem(at: self.root)
        WebUIUpdateProtocol.reset()
        try await super.tearDown()
    }

    func testCheckingIsPublishedBeforeRequestFinishesAndDuplicateActionsAreIgnored() async throws {
        let task = Task { await self.app.checkForWebUIUpdates(.metaCubeXD) }
        try await self.waitForRequest()
        XCTAssertEqual(self.app.webUIStatuses[.metaCubeXD]?.state, .checking)
        XCTAssertNil(self.app.webUIStatuses[.metaCubeXD]?.lastCheckedAt)
        try self.render("checking")
        await self.app.checkForWebUIUpdates(.metaCubeXD)
        await self.app.updateWebUI(.metaCubeXD)
        XCTAssertEqual(WebUIUpdateProtocol.requestCount, 1)
        XCTAssertEqual(self.app.webUIStatuses[.metaCubeXD]?.state, .checking)
        WebUIUpdateProtocol.complete()
        await task.value
        let status = try XCTUnwrap(self.app.webUIStatuses[.metaCubeXD])
        XCTAssertEqual(status.state, .available)
        XCTAssertEqual(status.latestVersion, status.currentVersion)
        XCTAssertNotNil(status.lastCheckedAt)
        XCTAssertNil(status.errorMessage)
        try self.render("up-to-date")
    }

    func testNewVersionProducesAnUpdateAvailableResult() async throws {
        let task = Task { await self.app.checkForWebUIUpdates(.metaCubeXD) }
        try await self.waitForRequest()
        WebUIUpdateProtocol.complete(version: "1.1.0")
        await task.value
        let status = try XCTUnwrap(self.app.webUIStatuses[.metaCubeXD])
        XCTAssertEqual(status.state, .updateAvailable)
        XCTAssertEqual(status.currentVersion, "1.0.0")
        XCTAssertEqual(status.latestVersion, "1.1.0")
        XCTAssertNotNil(status.lastCheckedAt)
        try self.render("update-available")
    }

    func testFailureIsVisibleAndRetryClearsThePreviousError() async throws {
        let failedTask = Task { await self.app.checkForWebUIUpdates(.metaCubeXD) }
        try await self.waitForRequest()
        WebUIUpdateProtocol.complete(statusCode: 503)
        await failedTask.value
        XCTAssertEqual(self.app.webUIStatuses[.metaCubeXD]?.state, .available)
        XCTAssertTrue(self.app.webUIStatuses[.metaCubeXD]?.errorMessage?.contains("503") == true)
        XCTAssertNil(self.app.webUIStatuses[.metaCubeXD]?.lastCheckedAt)
        try self.render("failed")
        let retryTask = Task { await self.app.checkForWebUIUpdates(.metaCubeXD) }
        try await self.waitForRequest()
        XCTAssertEqual(self.app.webUIStatuses[.metaCubeXD]?.state, .checking)
        XCTAssertNil(self.app.webUIStatuses[.metaCubeXD]?.errorMessage)
        WebUIUpdateProtocol.complete()
        await retryTask.value
        XCTAssertEqual(self.app.webUIStatuses[.metaCubeXD]?.state, .available)
        XCTAssertNil(self.app.webUIStatuses[.metaCubeXD]?.errorMessage)
        XCTAssertNotNil(self.app.webUIStatuses[.metaCubeXD]?.lastCheckedAt)
    }

    func testUpdatingIsPublishedBeforeRequestFinishesAndBlocksChecking() async throws {
        let task = Task { await self.app.updateWebUI(.metaCubeXD) }
        try await self.waitForRequest()
        XCTAssertEqual(self.app.webUIStatuses[.metaCubeXD]?.state, .updating)
        await self.app.checkForWebUIUpdates(.metaCubeXD)
        await self.app.updateWebUI(.metaCubeXD)
        XCTAssertEqual(WebUIUpdateProtocol.requestCount, 1)
        XCTAssertEqual(self.app.webUIStatuses[.metaCubeXD]?.state, .updating)
        WebUIUpdateProtocol.complete(statusCode: 503)
        await task.value
        XCTAssertEqual(self.app.webUIStatuses[.metaCubeXD]?.state, .available)
        XCTAssertNotNil(self.app.webUIStatuses[.metaCubeXD]?.errorMessage)
    }

    func testMissingAssetsRemainUnavailableAfterASuccessfulCheck() async throws {
        try FileManager.default.removeItem(at: self.app.webUIAssetService.currentDirectoryURL(for: .metaCubeXD))
        self.app.webUIAssetService.reloadStatus(for: .metaCubeXD)
        let task = Task { await self.app.checkForWebUIUpdates(.metaCubeXD) }
        try await self.waitForRequest()
        WebUIUpdateProtocol.complete()
        await task.value
        let status = try XCTUnwrap(self.app.webUIStatuses[.metaCubeXD])
        XCTAssertEqual(status.state, .unavailable)
        XCTAssertEqual(status.latestVersion, "1.0.0")
        XCTAssertNotNil(status.lastCheckedAt)
        XCTAssertNil(status.errorMessage)
        try self.render("not-installed")
    }

    private func waitForRequest() async throws {
        for _ in 0..<200 {
            if WebUIUpdateProtocol.hasPendingRequest { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("WebUI release request did not start")
        throw URLError(.timedOut)
    }

    private func render(_ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["CLASHBAR_WEBUI_SCREENSHOT_DIR"] else { return }
        _ = NSApplication.shared
        let previousLanguage = self.app.uiLanguage
        defer { self.app.uiLanguage = previousLanguage }
        self.app.uiLanguage = .zhHans
        let hosting = NSHostingView(rootView: SystemTabView().environmentObject(self.app)
            .environment(\.colorScheme, .light).padding(8).frame(width: MenuBarLayoutTokens.panelWidth).background(Color.white))
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertLessThanOrEqual(hosting.fittingSize.width, MenuBarLayoutTokens.panelWidth)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
