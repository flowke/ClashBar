import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppViewModel {
    func importRemoteConfigFile(
        manualOnly: Bool = false,
        dashboardErrors: Bool = false,
        source: RemoteConfigImportSource = .menuBar) async
    {
        guard let configDirectory = ensureConfigDirectoryAvailable() else { return }
        guard let input = await promptRemoteConfigImportInput(manualOnly: manualOnly, source: source) else { return }

        let urlText = input.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remoteURL = URL(string: urlText), isSupportedRemoteConfigURL(remoteURL) else {
            let message = tr("log.config.remote.invalid_url", urlText)
            appendLog(level: "error", message: message)
            if dashboardErrors { dashboardConfigError = message }
            else { self.presentRemoteConfigImportResultAlert(success: false, message: message) }
            return
        }

        let hostFallbackName = self.inferredRemoteConfigFileName(from: remoteURL)
        let requestedName = input.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requestedName.isEmpty {
            guard let fileName = normalizedConfigFileName(requestedName) else {
                let message = tr("log.config.import.invalid_filename", input.fileName)
                appendLog(level: "error", message: message)
                if dashboardErrors { dashboardConfigError = message }
                else { self.presentRemoteConfigImportResultAlert(success: false, message: message) }
                return
            }
            let targetURL = configDirectory.appendingPathComponent(fileName, isDirectory: false)
            guard !FileManager.default.fileExists(atPath: targetURL.path) else {
                let message = self.uiLanguage == .zhHans ? "同名配置已存在，请使用其他名称。" : "A configuration with this name already exists. Choose a different name."
                appendLog(level: "error", message: message)
                if dashboardErrors { dashboardConfigError = message }
                else { presentRemoteConfigImportResultAlert(success: false, message: message) }
                return
            }
        }
        var fileNameForLog = requestedName.isEmpty
            ? hostFallbackName
            : (normalizedConfigFileName(requestedName) ?? hostFallbackName)
        do {
            let userAgent = await remoteSubscriptionUserAgent()
            let download = try await configService.downloadRemoteConfig(from: remoteURL, userAgent: userAgent)
            let data = download.data
            try await validateDownloadedConfig(data, in: configDirectory)

            let embeddedName = download.suggestedName ?? self.configService.inferredRemoteConfigDisplayName(from: data)
            let isUsingAutomaticName = requestedName.isEmpty
            let fallbackName = isUsingAutomaticName ? (embeddedName ?? hostFallbackName) : hostFallbackName
            guard let fileName = normalizedConfigFileName(input.fileName, fallback: fallbackName) else {
                throw NSError(
                    domain: "ClashBar.ConfigImport",
                    code: 422,
                    userInfo: [NSLocalizedDescriptionKey: tr("log.config.import.invalid_filename", input.fileName)])
            }
            fileNameForLog = fileName
            let targetURL = configDirectory.appendingPathComponent(fileName, isDirectory: false)
            guard !FileManager.default.fileExists(atPath: targetURL.path) else {
                throw NSError(
                    domain: "ClashBar.ConfigImport",
                    code: CocoaError.fileWriteFileExists.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: self.uiLanguage == .zhHans
                        ? "同名配置已存在，请使用其他名称。"
                        : "A configuration with this name already exists. Choose a different name."])
            }
            try writeConfigData(data, to: targetURL)

            let subscription = RemoteConfigSubscription(
                urlString: remoteURL.absoluteString,
                displayName: isUsingAutomaticName ? embeddedName : nil,
                autoUpdateEnabled: input.autoUpdateEnabled,
                autoUpdateIntervalHours: input.autoUpdateIntervalHours,
                lastUpdateCheckAt: Date(),
                usage: download.usage)
            self.upsertRemoteConfigSubscription(for: fileName, subscription: subscription)
            let message = tr("log.config.import_remote.success", fileName)
            appendLog(level: "info", message: message)

            self.presentRemoteConfigImportResultAlert(success: true, message: message)
        } catch {
            let message = tr("log.config.import_remote.failed", fileNameForLog, error.localizedDescription)
            appendLog(level: "error", message: message)
            if dashboardErrors { dashboardConfigError = message }
            else { self.presentRemoteConfigImportResultAlert(success: false, message: message) }
        }
    }

    func updateAllRemoteConfigFiles() async {
        guard ensureConfigDirectoryAvailable() != nil else { return }
        pruneRemoteConfigSubscriptionsIfNeeded()

        let subscriptions = remoteConfigSubscriptions
        guard !subscriptions.isEmpty else {
            appendLog(level: "info", message: tr("log.config.remote.no_sources"))
            return
        }

        for fileName in subscriptions.keys.sorted() {
            await refreshRemoteConfigFile(named: fileName)
        }
    }

    func deleteConfigFile(named fileName: String, confirmed: Bool = false) async {
        if !confirmed {
            await deleteDashboardConfig(fileName)
            return
        }
        guard !dashboardConfigBusy else { return }
        guard confirmed || self.confirmDeleteConfig(named: fileName) else { return }
        guard let configDirectory = ensureConfigDirectoryAvailable() else { return }

        let targetURL = configDirectory.appendingPathComponent(fileName, isDirectory: false)
        let isDeletingSelected = fileName == selectedConfigName
        guard !isDeletingSelected || (!isRuntimeRunning && !isCoreActionProcessing) else {
            dashboardConfigError = uiLanguage == .zhHans ? "请先停止内核。" : "Stop the core first."
            return
        }
        do {
            if isDeletingSelected {
                dashboardEffectiveRecord = try effectiveConfigTransaction.deleteSelectedSource(targetURL)
                configService.clearSelection()
                selectedConfigName = "-"
                defaults.set("-", forKey: selectedConfigKey)
                defaults.removeObject(forKey: legacySelectedConfigKey)
                configDirectoryMonitor?.updateSelectedFile(nil)
            } else {
                try FileManager.default.removeItem(at: targetURL)
            }
        } catch {
            appendLog(level: "error", message: tr("log.config.delete.failed", fileName, error.localizedDescription))
            if confirmed { dashboardConfigError = error.localizedDescription }
            return
        }

        if fileName == "ClashBar.yaml" {
            defaults.set(true, forKey: "clashbar.config.bundled.deleted")
        }

        self.removeRemoteConfigSubscription(for: fileName)
        _ = configService.reloadConfigs()
        syncConfigDisplayState()

        appendLog(level: "info", message: tr("log.config.delete.success", fileName))

    }

    func confirmDeleteConfig(named fileName: String) -> Bool {
        self.runModalAlert(
            style: .warning,
            message: tr("app.config.delete.title", fileName),
            informative: fileName == selectedConfigName && isRuntimeRunning
                ? (uiLanguage == .zhHans ? "删除当前配置将停止内核并中断代理连接。远程订阅的更新信息也会被删除。" : "Deleting the current configuration will stop the core and interrupt proxy connections. Subscription metadata will also be removed.")
                : tr("app.config.delete.message"),
            buttons: [tr("ui.action.delete"), tr("ui.action.cancel")]) == .alertFirstButtonReturn
    }

    func showSelectedConfigInFinder() {
        guard let configDirectory = ensureConfigDirectoryAvailable() else { return }
        if let selected = configService.selectedConfig, FileManager.default.fileExists(atPath: selected.path) {
            NSWorkspace.shared.activateFileViewerSelecting([selected])
            return
        }

        if !NSWorkspace.shared.open(configDirectory) {
            appendLog(level: "error", message: tr("log.config.show_in_finder.failed", configDirectory.path))
        }
    }

    func showCoreDirectoryInFinder() {
        do {
            try workingDirectoryManager.bootstrapDirectories()
            let coreDirectory = try workingDirectoryManager.normalizeAndValidateWithinRoot(
                workingDirectoryManager.coreDirectoryURL,
                mustBeDirectory: true)
            if !NSWorkspace.shared.open(coreDirectory) {
                appendLog(level: "error", message: tr("log.core.show_in_finder.failed", coreDirectory.path))
            }
        } catch {
            appendLog(
                level: "error",
                message: tr("log.core.show_in_finder.failed", workingDirectoryManager.coreDirectoryURL.path))
        }
    }

    func reloadConfigFileList() {
        guard self.ensureConfigDirectoryAvailable() != nil else { return }
        self.refreshConfigStateAfterMutation()
        appendLog(level: "info", message: tr("log.config.loaded_count", configService.availableConfigs.count))
    }

    func refreshRemoteConfigMenuStates() {
        let subscriptions = self.remoteConfigSubscriptions
        guard !subscriptions.isEmpty else {
            self.remoteConfigMenuStates = [:]
            return
        }

        var nextStates: [String: RemoteConfigMenuState] = [:]
        nextStates.reserveCapacity(subscriptions.count)

        for (fileName, sub) in subscriptions {
            let updatedAt = self.remoteConfigUpdatedAt(for: fileName)
            nextStates[fileName] = self.mergedRemoteConfigMenuState(
                for: fileName,
                updatedAt: updatedAt,
                subscription: sub)
        }

        self.remoteConfigMenuStates = nextStates
    }

    func remoteConfigMenuState(for fileName: String) -> RemoteConfigMenuState {
        self.remoteConfigMenuStates[fileName] ?? .idle
    }

    func refreshRemoteConfigFile(named fileName: String) async {
        guard self.remoteConfigMenuState(for: fileName).phase != .refreshing else { return }
        guard let configDirectory = self.ensureConfigDirectoryAvailable() else { return }

        self.pruneRemoteConfigSubscriptionsIfNeeded()
        self.setRemoteConfigMenuState(for: fileName, phase: .refreshing)
        defer {
            if self.remoteConfigMenuState(for: fileName).phase == .refreshing {
                self.setRemoteConfigMenuState(for: fileName, phase: .idle)
            }
        }

        guard let sub = self.remoteConfigSubscriptions[fileName],
              let remoteURL = URL(string: sub.urlString),
              isSupportedRemoteConfigURL(remoteURL)
        else {
            let stored = self.remoteConfigSubscriptions[fileName]?.urlString ?? fileName
            let reason = tr("log.config.remote.invalid_url", stored)
            self.appendLog(level: "error", message: tr("log.config.remote.update_item_failed", fileName, reason))
            self.dashboardSubscriptionErrors[fileName] = reason
            self.setRemoteConfigMenuState(for: fileName, phase: .failed)
            return
        }
        guard sub.isEnabled else { return }
        dashboardSubscriptionErrors[fileName] = nil

        let checkAt = Date()
        do {
            let userAgent = await self.remoteSubscriptionUserAgent()
            let download = try await self.configService.downloadRemoteConfig(from: remoteURL, userAgent: userAgent)
            let data = download.data
            guard var refreshedSubscription = self.checkedRemoteConfigSubscription(
                for: fileName,
                baseline: sub,
                at: checkAt)
            else {
                return
            }
            let targetURL = configDirectory.appendingPathComponent(fileName, isDirectory: false)
            let original = try Data(contentsOf: targetURL)
            let didWrite = original != data
            if didWrite, fileName == self.selectedConfigName {
                let changes = (try self.effectiveConfigTransaction.currentRecord())?.changes ?? []
                guard await self.applyDashboardConfiguration(baseName: fileName, changes: changes, replacementSource: data, precondition: {
                    guard self.remoteConfigSubscriptions[fileName] == sub, self.selectedConfigName == fileName else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                }) else {
                    throw NSError(domain: "ClashBar.Config", code: 422,
                                  userInfo: [NSLocalizedDescriptionKey: self.dashboardConfigError ?? "Configuration update failed"])
                }
            } else if didWrite {
                try await validateDownloadedConfig(data, in: configDirectory)
                guard self.remoteConfigSubscriptions[fileName] == sub,
                      try Data(contentsOf: targetURL) == original else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try data.write(to: targetURL, options: .atomic)
            }

            refreshedSubscription.usage = download.usage
            if let displayName = download.suggestedName ?? self.configService.inferredRemoteConfigDisplayName(from: data) {
                refreshedSubscription.displayName = displayName
            }
            self.remoteConfigSubscriptions[fileName] = refreshedSubscription
            self.persistRemoteConfigSubscriptions()

            if didWrite {
                self.refreshConfigStateAfterMutation()
                self.syncConfigSignatureSnapshotToMonitorBaseline()
            }

            self.setRemoteConfigMenuState(
                for: fileName,
                phase: .idle,
                updatedAt: self.remoteConfigUpdatedAt(for: fileName) ?? Date())
        } catch {
            guard let refreshedSubscription = self.checkedRemoteConfigSubscription(
                for: fileName,
                baseline: sub,
                at: checkAt)
            else {
                return
            }
            self.remoteConfigSubscriptions[fileName] = refreshedSubscription
            self.persistRemoteConfigSubscriptions()
            self.appendLog(
                level: "error",
                message: tr("log.config.remote.update_item_failed", fileName, error.localizedDescription))
            self.dashboardSubscriptionErrors[fileName] = error.localizedDescription
            if self.dashboardConfigError == error.localizedDescription {
                self.dashboardConfigError = nil
            }
            self.setRemoteConfigMenuState(for: fileName, phase: .failed)
        }
    }

    func reloadConfig() async {
        cancelProxyPortRetry()
        await waitForProxyPortRetryToStop()
        let actionName = tr("log.action_name.reload_config")
        let expectedTunEnabled = isTunEnabled
        let previousProxyPorts = currentSystemProxyPortsFromState()

        do {
            ensureAPIClient()
            guard let configPath = await self.resolveSelectedConfigPath() else {
                appendLog(level: "error", message: tr("log.start.no_config"))
                return
            }
            try await self.clientOrThrow().requestNoResponse(.putConfigs(force: false, path: configPath, payload: nil))
            if !isRemoteTarget {
                try await self.applyRuntimeProxyPorts(configURL: URL(fileURLWithPath: configPath))
            }
            try await self.restoreTunAfterConfigReloadIfNeeded(expectedEnabled: expectedTunEnabled)
            await refreshFromAPI(includeSlowCalls: false)
            await syncSystemProxyPortIfNeeded(shouldSync: !isRemoteTarget, previousPorts: previousProxyPorts)
            appendLog(level: "info", message: tr("log.action.success", actionName))
        } catch {
            appendLog(level: "error", message: tr("log.action.failed", actionName, error.localizedDescription))
        }
    }

    func ensureConfigDirectoryAvailable() -> URL? {
        if let configDirectory = configService.configDirectory {
            return configDirectory
        }

        do {
            try workingDirectoryManager.bootstrapDirectories()
            configService.setConfigDirectory(workingDirectoryManager.configDirectoryURL)
            self.refreshConfigStateAfterMutation()
            return configService.configDirectory
        } catch {
            appendLog(level: "error", message: tr("log.working_dir_init_failed", error.localizedDescription))
            return nil
        }
    }

    private func refreshConfigStateAfterMutation() {
        _ = configService.reloadConfigs()
        if self.syncSelectedConfigSelection(configService.selectedConfig) == nil {
            selectedConfigName = "-"
            defaults.removeObject(forKey: selectedConfigKey)
        }
        syncConfigDisplayState()
    }

    @discardableResult
    func syncSelectedConfigSelection(_ selected: URL?) -> String? {
        self.configDirectoryMonitor?.updateSelectedFile(selected)
        guard let selected else { return nil }
        selectedConfigName = selected.lastPathComponent
        defaults.set(selected.lastPathComponent, forKey: selectedConfigKey)
        return selected.path
    }

    func shouldAutoReloadCurrentConfig(updatedFileNames: Set<String>) -> Bool {
        guard !updatedFileNames.isEmpty else { return false }
        guard isRuntimeRunning else { return false }
        guard !isRemoteTarget else { return false }
        return updatedFileNames.contains(selectedConfigName)
    }

    @discardableResult
    func writeConfigData(_ data: Data, to targetURL: URL) throws -> Bool {
        try configService.writeConfigData(data, to: targetURL)
    }

    func confirmOverwriteConfig(named fileName: String) -> Bool {
        self.runModalAlert(
            style: .warning,
            message: tr("app.config.import.overwrite.title", fileName),
            informative: tr("app.config.import.overwrite.message"),
            buttons: [tr("ui.action.overwrite"), tr("ui.action.cancel")]) == .alertFirstButtonReturn
    }

    private func presentRemoteConfigImportResultAlert(success: Bool, message: String) {
        self.runModalAlert(
            style: success ? .informational : .warning,
            message: success
                ? tr("app.config.remote_import.alert.success.title")
                : tr("app.config.remote_import.alert.failure.title"),
            informative: message,
            buttons: [tr("ui.action.ok")])
    }

    private func promptRemoteConfigImportInput(
        manualOnly: Bool,
        source: RemoteConfigImportSource) async -> RemoteConfigImportInput?
    {
        if let prompt = self.remoteConfigImportPrompt {
            prompt.focus()
            return nil
        }
        let anchorContext: PanelAnchorContext?
        switch source {
        case .menuBar:
            anchorContext = self.remoteConfigImportAnchorContextProvider?()
        case .dashboard:
            anchorContext = PanelAnchorContext.resolve(for: (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView)
        }
        let presenter = RemoteConfigImportPanelPresenter(
            appViewModel: self,
            manualOnly: manualOnly,
            source: source,
            anchorContext: anchorContext,
            copy: RemoteConfigImportPanelCopy(
                title: tr("ui.quick.import_remote_config"),
                description: tr("app.config.remote_import.prompt"),
                urlLabel: tr("ui.quick.remote.url_label"),
                urlPlaceholder: tr("ui.quick.remote.url_placeholder"),
                fileNameLabel: tr("ui.quick.remote.filename_label"),
                fileNamePlaceholder: tr("ui.quick.remote.filename_placeholder"),
                autoUpdateLabel: tr("ui.quick.remote.auto_update_label"),
                intervalEach: tr("ui.quick.remote.interval_each"),
                intervalUnit: tr("ui.quick.remote.interval_unit"),
                close: tr("ui.action.close"),
                cancel: tr("ui.action.cancel"),
                import: tr("ui.action.import")))
        self.remoteConfigImportPrompt = presenter
        let input = await presenter.present()
        if self.remoteConfigImportPrompt === presenter {
            self.remoteConfigImportPrompt = nil
        }
        return input
    }

    func normalizedConfigFileName(_ fileName: String, fallback: String? = nil) -> String? {
        configService.normalizedConfigFileName(fileName, fallback: fallback)
    }

    private func inferredRemoteConfigFileName(from remoteURL: URL) -> String {
        configService.inferredRemoteConfigFileName(from: remoteURL)
    }

    func isSupportedRemoteConfigURL(_ url: URL) -> Bool {
        configService.isSupportedRemoteConfigURL(url)
    }

    private func downloadRemoteConfigData(from remoteURL: URL, userAgent: String? = nil) async throws -> Data {
        try await configService.downloadRemoteConfigData(from: remoteURL, userAgent: userAgent)
    }

    private func validateDownloadedConfig(_ data: Data, in directory: URL) async throws {
        let candidate = directory.appendingPathComponent(".clashbar-validation-\(UUID().uuidString).yaml")
        defer { try? FileManager.default.removeItem(at: candidate) }
        _ = try ConfigRuleMerger().merge(data, changes: [])
        try data.write(to: candidate, options: .atomic)
        try await processManager.validateConfigAsync(configPath: candidate.path)
    }

    private static let defaultMihomoVersionForUserAgent = "v1.19.27"

    private func remoteSubscriptionUserAgent() async -> String {
        let version = await resolvedMihomoVersionForSubscriptionUserAgent()
        return "clash.meta/\(version)"
    }

    private func resolvedMihomoVersionForSubscriptionUserAgent() async -> String {
        if let current = normalizedMihomoVersionForUserAgent(self.version) {
            return current
        }

        guard let client = try? clientOrThrow() else {
            return Self.defaultMihomoVersionForUserAgent
        }

        guard let fetched: VersionInfo = try? await client.request(.version) else {
            return Self.defaultMihomoVersionForUserAgent
        }

        let normalized = self.normalizedMihomoVersionForUserAgent(fetched.version) ?? Self
            .defaultMihomoVersionForUserAgent
        if normalized != Self.defaultMihomoVersionForUserAgent {
            self.version = normalized
        }
        return normalized
    }

    private func normalizedMihomoVersionForUserAgent(_ rawVersion: String) -> String? {
        let trimmed = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-" else { return nil }
        return trimmed
    }

    func restoreTunAfterConfigReloadIfNeeded(expectedEnabled: Bool) async throws {
        guard isRuntimeRunning else { return }
        try await self.patchTunConfig(enable: expectedEnabled)
        try await self.verifyTunRuntimeState(expectedEnabled: expectedEnabled)
        if isTunEnabled != expectedEnabled {
            isTunEnabled = expectedEnabled
            persistEditableSettingsSnapshot()
        }
    }

    private func upsertRemoteConfigSubscription(for fileName: String, subscription: RemoteConfigSubscription) {
        remoteConfigSubscriptions[fileName] = subscription
        persistRemoteConfigSubscriptions()
        self.restartRemoteConfigBackgroundTasksIfNeeded()
        self.refreshConfigStateAfterMutation()
    }

    func removeRemoteConfigSubscription(for fileName: String) {
        guard remoteConfigSubscriptions[fileName] != nil else { return }
        remoteConfigSubscriptions.removeValue(forKey: fileName)
        persistRemoteConfigSubscriptions()
        self.restartRemoteConfigBackgroundTasksIfNeeded()
        self.refreshConfigStateAfterMutation()
    }

    private func checkedRemoteConfigSubscription(
        for fileName: String,
        baseline: RemoteConfigSubscription,
        at checkAt: Date) -> RemoteConfigSubscription?
    {
        guard self.remoteConfigSubscriptions[fileName] == baseline else { return nil }
        return baseline.markChecked(at: checkAt)
    }

    private func remoteConfigUpdatedAt(for fileName: String) -> Date? {
        guard let configURL = self.configService.availableConfigs.first(where: { $0.lastPathComponent == fileName })
        else {
            return nil
        }
        return try? configURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func mergedRemoteConfigMenuState(
        for fileName: String,
        updatedAt: Date?,
        subscription: RemoteConfigSubscription) -> RemoteConfigMenuState
    {
        let current = self.remoteConfigMenuStates[fileName] ?? .idle
        let phase: RemoteConfigRefreshPhase = switch current.phase {
        case .refreshing:
            .refreshing
        case .failed:
            current.updatedAt == updatedAt ? .failed : .idle
        case .idle:
            .idle
        }
        return RemoteConfigMenuState(
            updatedAt: updatedAt,
            phase: phase,
            autoUpdateEnabled: subscription.autoUpdateEnabled,
            nextUpdateAt: subscription.nextUpdateAt())
    }

    private func setRemoteConfigMenuState(
        for fileName: String,
        phase: RemoteConfigRefreshPhase,
        updatedAt: Date? = nil)
    {
        let existing = self.remoteConfigMenuStates[fileName]
        let sub = self.remoteConfigSubscriptions[fileName]
        let resolvedUpdatedAt = updatedAt ?? existing?.updatedAt
        self.remoteConfigMenuStates[fileName] = RemoteConfigMenuState(
            updatedAt: resolvedUpdatedAt,
            phase: phase,
            autoUpdateEnabled: sub?.autoUpdateEnabled ?? false,
            nextUpdateAt: sub?.nextUpdateAt())
    }

    func startRemoteConfigAutoUpdateTaskIfNeeded() {
        guard remoteConfigAutoUpdateTask == nil || remoteConfigAutoUpdateTask?.isCancelled == true else { return }
        let hasAutoUpdate = remoteConfigSubscriptions.values.contains { $0.autoUpdateEnabled }
        guard hasAutoUpdate else { return }
        remoteConfigAutoUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.performDueRemoteConfigAutoUpdatesIfNeeded()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    break
                }
            }
        }
    }

    func stopRemoteConfigAutoUpdateTask() {
        remoteConfigAutoUpdateTask?.cancel()
        remoteConfigAutoUpdateTask = nil
    }

    func restartRemoteConfigAutoUpdateTaskIfNeeded() {
        self.stopRemoteConfigAutoUpdateTask()
        self.startRemoteConfigAutoUpdateTaskIfNeeded()
    }

    func restartRemoteConfigBackgroundTasksIfNeeded() {
        self.restartRemoteConfigAutoUpdateTaskIfNeeded()
        self.stopRemoteConfigMenuRefreshTimer()
        self.startRemoteConfigMenuRefreshTimerIfNeeded()
    }

    func performDueRemoteConfigAutoUpdatesIfNeeded() async {
        let due = remoteConfigSubscriptions
            .compactMap { $0.value.isDue() ? $0.key : nil }
            .sorted()
        guard !due.isEmpty else { return }
        for fileName in due {
            guard !Task.isCancelled else { break }
            await self.refreshRemoteConfigFile(named: fileName)
        }
    }

    func startRemoteConfigMenuRefreshTimerIfNeeded() {
        guard remoteConfigMenuRefreshTask == nil || remoteConfigMenuRefreshTask?.isCancelled == true else { return }
        guard !remoteConfigSubscriptions.isEmpty else { return }
        remoteConfigMenuRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    break
                }
                self?.refreshRemoteConfigMenuStates()
            }
        }
    }

    func stopRemoteConfigMenuRefreshTimer() {
        remoteConfigMenuRefreshTask?.cancel()
        remoteConfigMenuRefreshTask = nil
    }
}

enum RemoteConfigImportSource {
    case menuBar
    case dashboard
}

struct RemoteConfigImportInput {
    let urlString: String
    let fileName: String
    let autoUpdateEnabled: Bool
    let autoUpdateIntervalHours: Int
}

struct RemoteConfigImportPanelCopy {
    let title: String
    let description: String
    let urlLabel: String
    let urlPlaceholder: String
    let fileNameLabel: String
    let fileNamePlaceholder: String
    let autoUpdateLabel: String
    let intervalEach: String
    let intervalUnit: String
    let close: String
    let cancel: String
    let `import`: String
}

@MainActor
private final class RemoteConfigImportWindow: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

@MainActor
final class RemoteConfigImportPanelPresenter: NSObject, NSWindowDelegate {
    let window: NSPanel
    private let source: RemoteConfigImportSource
    private let anchorContext: PanelAnchorContext?
    private var continuation: CheckedContinuation<RemoteConfigImportInput?, Never>?

    init(
        appViewModel: AppViewModel,
        manualOnly: Bool,
        source: RemoteConfigImportSource,
        anchorContext: PanelAnchorContext?,
        copy: RemoteConfigImportPanelCopy)
    {
        self.source = source
        self.anchorContext = anchorContext
        let panelSize = NSSize(width: 432, height: manualOnly ? 264 : 336)
        let panel = RemoteConfigImportWindow(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        self.window = panel
        super.init()

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.delegate = self
        appViewModel.configureModalWindow(panel)

        let hostingController = NSHostingController(rootView: RemoteConfigImportForm(
            manualOnly: manualOnly,
            copy: copy,
            onImport: { [weak self] input in self?.finish(input) },
            onCancel: { [weak self] in self?.finish(nil) }))
        hostingController.sizingOptions = []
        panel.contentViewController = hostingController
        panel.setContentSize(panelSize)
        self.placePanel()
    }

    func present() async -> RemoteConfigImportInput? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.focus()
        }
    }

    func focus() {
        NSApp.activate(ignoringOtherApps: true)
        self.window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        self.finish(nil, closeWindow: false)
    }

    private func placePanel() {
        let panelSize = self.window.frame.size
        let placement: PanelPlacement?
        if let anchorContext {
            switch self.source {
            case .menuBar:
                placement = anchorContext.menuBarDropdownPlacement(
                    panelSize: panelSize,
                    options: MenuBarDropdownPlacementOptions(
                        horizontalPadding: 10,
                        verticalSpacing: 6,
                        screenPadding: 10,
                        lockedOriginX: nil,
                        preserveHorizontalPosition: false))
            case .dashboard:
                placement = anchorContext.centeredWindowPlacement(panelSize: panelSize, screenPadding: 16)
            }
        } else {
            placement = nil
        }

        if let placement {
            self.window.setFrame(placement.frame, display: false)
        } else if let visibleFrame = NSScreen.main?.visibleFrame {
            let origin = CGPoint(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.midY - panelSize.height / 2)
            self.window.setFrame(CGRect(origin: origin, size: panelSize), display: false)
        }
    }

    private func finish(_ input: RemoteConfigImportInput?, closeWindow: Bool = true) {
        guard let continuation else { return }
        self.continuation = nil
        if closeWindow {
            self.window.close()
        }
        continuation.resume(returning: input)
    }
}

@MainActor
private struct RemoteConfigImportForm: View {
    let manualOnly: Bool
    let copy: RemoteConfigImportPanelCopy
    let onImport: (RemoteConfigImportInput) -> Void
    let onCancel: () -> Void

    @State private var urlString = ""
    @State private var fileName = ""
    @State private var autoUpdateEnabled = true
    @State private var intervalHours = "\(RemoteConfigSubscription.defaultAutoUpdateIntervalHours)"
    @FocusState private var isURLFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(self.copy.title)
                        .font(.headline)
                    Text(self.copy.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button(action: self.onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(self.copy.close)
                .accessibilityLabel(self.copy.close)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(self.copy.urlLabel)
                    .font(.callout.weight(.medium))
                TextField(self.copy.urlPlaceholder, text: self.$urlString)
                    .textFieldStyle(.roundedBorder)
                    .focused(self.$isURLFocused)
                    .onSubmit(self.submit)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(self.copy.fileNameLabel)
                    .font(.callout.weight(.medium))
                TextField(self.copy.fileNamePlaceholder, text: self.$fileName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(self.submit)
            }

            if !self.manualOnly {
                VStack(spacing: 10) {
                    Divider()
                    HStack(spacing: 8) {
                        Toggle(self.copy.autoUpdateLabel, isOn: self.$autoUpdateEnabled)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                        Spacer(minLength: 6)
                        Text(self.copy.intervalEach)
                            .foregroundStyle(.secondary)
                        TextField("", text: self.$intervalHours)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 52)
                            .multilineTextAlignment(.center)
                            .disabled(!self.autoUpdateEnabled)
                            .onSubmit(self.submit)
                        Text(self.copy.intervalUnit)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Spacer()
                Button(self.copy.cancel, action: self.onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(self.copy.import) {
                    self.submit()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 432, height: self.manualOnly ? 264 : 336)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task {
            await Task.yield()
            self.isURLFocused = true
        }
    }

    private func submit() {
        let parsedInterval = Int(self.intervalHours) ?? RemoteConfigSubscription.defaultAutoUpdateIntervalHours
        self.onImport(RemoteConfigImportInput(
            urlString: self.urlString,
            fileName: self.fileName,
            autoUpdateEnabled: !self.manualOnly && self.autoUpdateEnabled,
            autoUpdateIntervalHours: max(RemoteConfigSubscription.minimumAutoUpdateIntervalHours, parsedInterval)))
    }
}
