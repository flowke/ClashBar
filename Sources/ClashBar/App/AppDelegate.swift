import AppKit
import SwiftUI

@MainActor
final class ClashBarAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let managedModalWindowIdentifier = NSUserInterfaceItemIdentifier("ClashBar.ManagedModalWindow")
    let appViewModel = AppViewModel(dependencies: .live)
    private var statusItemController: StatusItemController?
    private var dashboardWindow: NSWindow?
    private var windowObservers: [any NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "NSQuitAlwaysKeepsWindows": false,
            "NSWindowRestorationSupported": false,
        ])

        if let image = BrandIcon.image {
            NSApp.applicationIconImage = image
        }
        NSApp.setActivationPolicy(.accessory)

        self.setupWindowSuppression()
        self.suppressNonPanelWindows()

        self.appViewModel.start()
        self.statusItemController = StatusItemController(appViewModel: self.appViewModel) { [weak self] in
            self?.showDashboard()
        }

        DispatchQueue.main.async { [weak self] in
            self?.suppressNonPanelWindows()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.suppressNonPanelWindows()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        self.statusItemController?.presentPopover()
        return false
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        self.suppressNonPanelWindows()
        self.restoreManagedModalWindowIfNeeded()
        self.appViewModel.handleApplicationDidBecomeActive()
    }

    func restoreManagedModalWindowIfNeeded() {
        guard let window = NSApp.modalWindow,
              window.identifier == Self.managedModalWindowIdentifier else { return }
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in self.windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.windowObservers.removeAll()

        self.appViewModel.shutdownForTermination()
        self.statusItemController?.shutdown()
        self.statusItemController = nil
    }

    func showSettingsPanel() {
        self.statusItemController?.presentPopover(tab: .system)
    }

    func showDashboard() {
        if self.dashboardWindow == nil {
            let window = DashboardWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                // Let the sidebar and detail backgrounds extend behind the
                // native titlebar controls.
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false)
            window.title = L10n.t("ui.action.open_dashboard", language: self.appViewModel.uiLanguage)
            window.minSize = NSSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            let hosting = NSHostingController(rootView:
                DashboardView(appViewModel: self.appViewModel, sidebarState: window.sidebarState).preferredColorScheme(.light))
            hosting.sizingOptions = []
            window.contentViewController = hosting
            window.configureTitlebar()
            window.setContentSize(NSSize(width: 1100, height: 740))
            window.center()
            self.dashboardWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        if self.dashboardWindow?.isMiniaturized == true {
            self.dashboardWindow?.deminiaturize(nil)
        }
        self.dashboardWindow?.makeKeyAndOrderFront(nil)
        self.appViewModel.setDashboardVisibility(true)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === self.dashboardWindow else { return }
        self.appViewModel.setDashboardVisibility(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === self.dashboardWindow else { return }
        self.appViewModel.setDashboardVisibility(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard notification.object as? NSWindow === self.dashboardWindow else { return }
        self.appViewModel.setDashboardVisibility(true)
    }

    private func setupWindowSuppression() {
        let center = NotificationCenter.default
        let notifications: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
        ]

        for name in notifications {
            let observer = center.addObserver(
                forName: name,
                object: nil,
                queue: .main)
            { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    self?.suppressWindowIfNeeded(window)
                }
            }
            self.windowObservers.append(observer)
        }
    }

    func suppressWindowIfNeeded(_ window: NSWindow) {
        if window.identifier == Self.managedModalWindowIdentifier || window === NSApp.modalWindow {
            return
        }
        if window is DashboardWindow {
            return
        }
        if window is NSPanel {
            return
        }
        let className = String(describing: type(of: window))
        if className.contains("StatusBar") ||
            className.contains("MenuBar") ||
            className.contains("Popover") ||
            className.contains("Alert") ||
            className.contains("_NSFullScreenTransition")
        {
            return
        }
        if window.sheetParent != nil {
            return
        }
        window.orderOut(nil)
        window.close()
    }

    private func suppressNonPanelWindows() {
        for window in NSApp.windows {
            self.suppressWindowIfNeeded(window)
        }
    }
}
