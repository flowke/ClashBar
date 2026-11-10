import AppKit
import SwiftUI
import XCTest
@testable import ClashBar

@MainActor
final class DashboardRenderingTests: XCTestCase {
    func testLongSourcePreviewRemainsBoundedAndScrollable() throws {
        _ = NSApplication.shared
        let contents = Array(repeating: String(repeating: "x", count: 300), count: 1000).joined(separator: "\n")
        let hosting = NSHostingView(rootView: DashboardSourcePreview(name: "test.yaml", contents: contents, closeTitle: "Close", close: {})
            .background(Color.white).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        XCTAssertEqual(hosting.fittingSize.width, 620, accuracy: 1)
        XCTAssertEqual(hosting.fittingSize.height, 480, accuracy: 1)
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let scroll = try XCTUnwrap(scrollViews(in: hosting).first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertFalse((document as? NSTextView)?.isHorizontallyResizable ?? true)
        XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height)
        XCTAssertLessThanOrEqual(document.frame.width, scroll.contentSize.width + 1)
        let textView = try XCTUnwrap(document as? NSTextView)
        XCTAssertEqual(textView.string, contents)
        XCTAssertEqual(textView.textContainer?.lineBreakMode, .byCharWrapping)
        if let path = ProcessInfo.processInfo.environment["CLASHBAR_PREVIEW_SNAPSHOT_PATH"] {
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testConfigurationRendersAtNarrowWidth() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = WorkingDirectoryManager(homeDirectory: root)
        try directory.bootstrapDirectories()
        let local = directory.configDirectoryURL.appendingPathComponent("Local.yaml")
        let remote = directory.configDirectoryURL.appendingPathComponent("Subscription.yaml")
        try Data("rules: ['DOMAIN,ads.example.com,DIRECT', 'DOMAIN,old.example.com,DIRECT', 'MATCH,DIRECT']".utf8).write(to: local)
        try Data("rules: ['MATCH,DIRECT']".utf8).write(to: remote)
        let session = URLSessionFactory.makeEphemeralSession(options: .init(timeoutIntervalForRequest: 15, timeoutIntervalForResource: 30))
        let service = ConfigService(configManager: ConfigDirectoryManager(workingDirectoryManager: directory), configImportService: ConfigImportService())
        service.setConfigDirectory(directory.configDirectoryURL)
        service.selectConfig(local)
        let dependencies = AppDependencies(
            processManager: MihomoProcessManager(workingDirectoryManager: directory), configService: service,
            systemProxyService: SystemProxyService(), tunPermissionService: TunPermissionService(),
            launchAtLoginService: AppLaunchService(), workingDirectoryManager: directory,
            networkReachabilityMonitor: NetworkReachabilityMonitor(), ssidMonitorService: SSIDMonitorService(),
            remoteMachineStore: RemoteMachineStore(session: session),
            proxyGroupIconCache: ProxyGroupIconCache(iconDirectory: directory.iconDirectoryURL, session: session),
            webUIAssetService: WebUIAssetService(workingDirectoryManager: directory, session: session),
            clashbarLogStore: AppLogStore(logFileURL: directory.logsDirectoryURL.appendingPathComponent("clashbar.log")),
            mihomoLogStore: AppLogStore(logFileURL: directory.logsDirectoryURL.appendingPathComponent("mihomo.log")))
        let model = AppViewModel(dependencies: dependencies)
        model.availableConfigFileNames = ["Local.yaml", "Subscription.yaml"]
        model.selectedConfigName = "Local.yaml"
        model.remoteConfigSubscriptions["Subscription.yaml"] = RemoteConfigSubscription(
            urlString: "https://example.test/config", usage: SubscriptionUsage(upload: 1_000, download: 2_000, total: 10_000, expiresAt: nil))
        if let directoryPath = ProcessInfo.processInfo.environment["CLASHBAR_SCREENSHOT_DIR"] {
            model.uiLanguage = .zhHans
            let sampleRules = [
                CustomRuleChange(operation: .add, original: "", value: "DOMAIN-SUFFIX,example.com,DIRECT"),
                CustomRuleChange(operation: .replace, original: "DOMAIN,ads.example.com,DIRECT", value: "DOMAIN,ads.example.com,REJECT"),
                CustomRuleChange(operation: .delete, original: "DOMAIN,old.example.com,DIRECT", value: "")
            ]
            let record = EffectiveConfigRecord(fileName: ".clashbar-effective-test.yaml", baseName: "Local.yaml", changes: sampleRules)
            try JSONEncoder().encode(record).write(to: directory.stateDirectoryURL.appendingPathComponent("effective-config.json"))
            try Data("rules: ['MATCH,DIRECT']".utf8).write(to: directory.configDirectoryURL.appendingPathComponent(record.fileName))
            service.selectConfig(local)
            model.selectedConfigName = "Local.yaml"
            model.dashboardConfigError = nil
            let samples: [(String, DashboardView.Page, Int)] = [
                ("overview", .overview, 0), ("effective", .configuration, 0),
                ("custom", .configuration, 1), ("sources", .configuration, 2),
                ("sources-error", .configuration, 2)
            ]
            for (name, page, tab) in samples {
                if name == "sources-error" {
                    model.remoteConfigMenuStates["Subscription.yaml"] = RemoteConfigMenuState(updatedAt: nil, phase: .failed, autoUpdateEnabled: false, nextUpdateAt: nil)
                    model.dashboardSubscriptionErrors["Subscription.yaml"] = "Could not connect to the server."
                }
                let sampleWindow = DashboardWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                let content = DashboardView(appViewModel: model, sidebarState: sampleWindow.sidebarState, initialPage: page, initialConfigurationTab: tab)
                    .environment(\.colorScheme, .light)
                let controller = NSHostingController(rootView: content)
                controller.sizingOptions = []
                sampleWindow.contentViewController = controller
                sampleWindow.configureTitlebar()
                sampleWindow.setContentSize(NSSize(width: 1100, height: 740))
                let host = try XCTUnwrap(sampleWindow.contentView)
                sampleWindow.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                sampleWindow.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                sampleWindow.displayIfNeeded()
                let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directoryPath).appendingPathComponent("\(name).png"), options: .atomic)
                if name == "effective" {
                    sampleWindow.setContentSize(NSSize(width: 760, height: 520))
                    host.layoutSubtreeIfNeeded()
                    sampleWindow.displayIfNeeded()
                    let resized = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: resized)
                    let titlebarSidebarColor = try XCTUnwrap(resized.colorAt(x: 4, y: 4))
                    let sidebarColor = try XCTUnwrap(resized.colorAt(x: 4, y: resized.pixelsHigh / 2))
                    let footerColor = try XCTUnwrap(resized.colorAt(x: 4, y: resized.pixelsHigh - 4))
                    XCTAssertEqual(titlebarSidebarColor.redComponent, 238 / 255, accuracy: 0.01)
                    XCTAssertEqual(sidebarColor.redComponent, 238 / 255, accuracy: 0.01)
                    XCTAssertEqual(footerColor.redComponent, 238 / 255, accuracy: 0.01)
                    XCTAssertEqual(sidebarColor.redComponent, footerColor.redComponent, accuracy: 0.01)
                    XCTAssertEqual(titlebarSidebarColor.redComponent, footerColor.redComponent, accuracy: 0.01)
                    try XCTUnwrap(resized.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directoryPath).appendingPathComponent("sidebar-narrow.png"), options: .atomic)
                    if ProcessInfo.processInfo.environment["CLASHBAR_TEST_SIDEBAR_MOTION"] == "1" {
                        func splitViews(in view: NSView) -> [NSSplitView] {
                            (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap { splitViews(in: $0) }
                        }
                        let split = try XCTUnwrap(splitViews(in: host).first)
                        sampleWindow.makeKeyAndOrderFront(nil)
                        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                        let expandedWidth = split.subviews[1].frame.width
                        XCTAssertGreaterThan(expandedWidth, 200)
                        let togglePoint = NSPoint(x: 200, y: sampleWindow.frame.height - 25)
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: togglePoint, modifierFlags: [], timestamp: 0, windowNumber: sampleWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                            sampleWindow.sendEvent(event)
                        }
                        var closingWidths: [CGFloat] = []
                        for delay in [0.05, 0.1, 0.3] {
                            RunLoop.current.run(until: Date().addingTimeInterval(delay))
                            closingWidths.append(split.subviews[1].frame.width)
                        }
                        XCTAssertTrue(closingWidths.contains { $0 > 0 && $0 < expandedWidth })
                        XCTAssertEqual(try XCTUnwrap(closingWidths.last), 0, accuracy: 1)
                        host.layoutSubtreeIfNeeded()
                        sampleWindow.displayIfNeeded()
                        let collapsed = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: collapsed)
                        let scale = CGFloat(collapsed.pixelsWide) / host.bounds.width
                        let buttonColor = try XCTUnwrap(collapsed.colorAt(x: Int(130 * scale), y: Int(12 * scale)))
                        XCTAssertGreaterThan(buttonColor.redComponent, 0.94)
                        try XCTUnwrap(collapsed.representation(using: .png, properties: [:]))
                            .write(to: URL(fileURLWithPath: directoryPath).appendingPathComponent("sidebar-motion-collapsed.png"), options: .atomic)
                        let restorePoint = NSPoint(x: 130, y: sampleWindow.frame.height - 25)
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: restorePoint, modifierFlags: [], timestamp: 0, windowNumber: sampleWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                            sampleWindow.sendEvent(event)
                        }
                        var openingWidths: [CGFloat] = []
                        for delay in [0.05, 0.1, 0.3] {
                            RunLoop.current.run(until: Date().addingTimeInterval(delay))
                            openingWidths.append(split.subviews[1].frame.width)
                        }
                        XCTAssertTrue(openingWidths.contains { $0 > 0 && $0 < expandedWidth })
                        XCTAssertEqual(try XCTUnwrap(openingWidths.last), expandedWidth, accuracy: 1)
                    }
                }
                sampleWindow.orderOut(nil)
            }
            let editor = DashboardCustomRulesView(
                appViewModel: model,
                request: .constant(DashboardCustomRuleRequest(operation: .add)))
                .frame(width: 800, alignment: .topLeading)
                .padding(32).background(Color.white).environment(\.colorScheme, .light)
            let editorHost = NSHostingView(rootView: editor)
            let editorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 864, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            editorWindow.contentView = editorHost
            editorWindow.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            editorWindow.orderFrontRegardless()
            editorHost.layoutSubtreeIfNeeded()
            editorWindow.displayIfNeeded()
            let editorImage = try XCTUnwrap(editorHost.bitmapImageRepForCachingDisplay(in: editorHost.bounds))
            editorHost.cacheDisplay(in: editorHost.bounds, to: editorImage)
            try XCTUnwrap(editorImage.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directoryPath).appendingPathComponent("custom-editor.png"), options: .atomic)
            editorWindow.orderOut(nil)
        }
        model.selectedConfigName = "Subscription.yaml"
        let view = DashboardConfigurationView(appViewModel: model, initialTab: 2)
            .padding(24).frame(width: 500).background(Color.white).environment(\.colorScheme, .light)
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        if let path = ProcessInfo.processInfo.environment["CLASHBAR_SNAPSHOT_PATH"] {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        XCTAssertGreaterThan(bitmap.pixelsHigh, 200)
        window.orderOut(nil)
        session.invalidateAndCancel()
    }

    func testSidebarUsesTransparentFullSizeTitlebarAndKeepsSystemWindowControls() throws {
        _ = NSApplication.shared
        let window = DashboardWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: Color.white)
        window.configureTitlebar()
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(type))
            XCTAssertFalse(button.isDescendant(of: content))
            XCTAssertNotNil(button.superview)
            XCTAssertNotNil(button.action)
        }
        window.setContentSize(NSSize(width: 760, height: 520))
        content.layoutSubtreeIfNeeded()
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertFalse(close.isDescendant(of: content))
        XCTAssertNotNil(close.superview)
    }
}
