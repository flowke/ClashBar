import AppKit

@MainActor
final class NonModalAlertPresenter: NSObject, NSWindowDelegate {
    let alert: NSAlert
    private var continuation: CheckedContinuation<NSApplication.ModalResponse, Never>?

    init(alert: NSAlert) {
        self.alert = alert
        super.init()
        alert.window.isReleasedWhenClosed = false
        alert.window.delegate = self
        for (index, button) in alert.buttons.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(self.selectButton(_:))
        }
    }

    func present() async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.show()
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        self.alert.window.makeKeyAndOrderFront(nil)
    }

    @objc private func selectButton(_ button: NSButton) {
        self.finish(NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + button.tag))
    }

    func windowWillClose(_ notification: Notification) {
        self.finish(.cancel, closeWindow: false)
    }

    private func finish(_ response: NSApplication.ModalResponse, closeWindow: Bool = true) {
        guard let continuation = self.continuation else { return }
        self.continuation = nil
        if closeWindow { self.alert.window.close() }
        continuation.resume(returning: response)
    }
}

@MainActor
extension AppViewModel {
    func prepareModalWindowPresentation() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func configureModalWindow(_ window: NSWindow) {
        window.identifier = ClashBarAppDelegate.managedModalWindowIdentifier
        window.level = .statusBar
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    @discardableResult
    func runModalAlert(
        style: NSAlert.Style,
        message: String,
        informative: String,
        buttons: [String],
        configure: ((NSAlert) -> Void)? = nil) -> NSApplication.ModalResponse
    {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = informative
        for title in buttons {
            alert.addButton(withTitle: title)
        }
        configure?(alert)
        self.configureModalWindow(alert.window)
        self.prepareModalWindowPresentation()
        return alert.runModal()
    }
}

@MainActor
extension AppViewModel {
    func presentCoreFailureAlert(
        title: String,
        message: String,
        dedupeKey: String,
        style: NSAlert.Style = .warning)
    {
        let now = Date()
        if self.lastCoreFailureAlertKey == dedupeKey,
           let lastAt = self.lastCoreFailureAlertAt,
           now.timeIntervalSince(lastAt) < self.coreFailureAlertThrottleInterval
        {
            return
        }

        self.lastCoreFailureAlertKey = dedupeKey
        self.lastCoreFailureAlertAt = now

        self.runModalAlert(
            style: style,
            message: title,
            informative: message,
            buttons: [tr("ui.action.ok")])
    }

    func presentConfigValidationFailedAlert(fileName: String, details: String) {
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)

        var informativeParts = [tr("app.config.validation_failed.message", fileName)]
        if Self.validationFailureLooksGeoRelated(trimmedDetails) {
            informativeParts.append(tr("app.config.validation_failed.hint.geo"))
        }
        informativeParts.append(tr("app.config.validation_failed.hint.common"))

        let response = self.runModalAlert(
            style: .critical,
            message: tr("app.config.validation_failed.title"),
            informative: informativeParts.joined(separator: "\n\n"),
            buttons: [tr("ui.action.ok"), tr("ui.action.copy_details")])
        { alert in
            alert.setScrollableDetails(trimmedDetails.isEmpty ? self.tr("ui.common.unknown") : trimmedDetails)
        }

        if response == .alertSecondButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(trimmedDetails, forType: .string)
        }
    }

    private static func validationFailureLooksGeoRelated(_ details: String) -> Bool {
        let lower = details.lowercased()
        let needles = [
            "geoip", "geosite", "mmdb", "geox-url", "geodata",
            "country.mmdb", "geosite.dat", "geoip.dat", ".metadb", "geolite", "asn",
        ]
        return needles.contains { lower.contains($0) }
    }

}
