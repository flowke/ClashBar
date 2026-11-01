import AppKit

@MainActor
final class ClashBarAppDelegate: NSObject, NSApplicationDelegate {
    let appViewModel = AppViewModel(dependencies: .live)
    private var statusItemController: StatusItemController?
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
        self.statusItemController = StatusItemController(appViewModel: self.appViewModel)
        self.appViewModel.presentInitialNoCoreSetupGuideIfNeeded()

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
        self.appViewModel.handleApplicationDidBecomeActive()
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

    private func suppressWindowIfNeeded(_ window: NSWindow) {
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
