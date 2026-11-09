import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
extension AppViewModel {
    func seedBundledConfigIfNeeded() {
        if defaults.bool(forKey: "clashbar.config.bundled.deleted") { return }
        if (try? effectiveConfigTransaction.currentRecord())?.baseName == "" { return }
        let fileManager = FileManager.default
        let targetURL = workingDirectoryManager.configDirectoryURL
            .appendingPathComponent("ClashBar.yaml", isDirectory: false)

        if fileManager.fileExists(atPath: targetURL.path) {
            return
        }

        guard let bundledConfigURL = bundledDefaultConfigURL(fileManager: fileManager) else {
            return
        }

        do {
            let data = try Data(contentsOf: bundledConfigURL)
            try writeConfigData(data, to: targetURL)
        } catch {
            appendLog(
                level: "error",
                message: tr("log.config.import_local.failed", "ClashBar.yaml", error.localizedDescription))
        }
    }

    private func bundledDefaultConfigURL(fileManager: FileManager = .default) -> URL? {
        AppResourceBundleLocator.bundledConfigTemplateURL(fileManager: fileManager)
    }

    func selectConfig() async {
        guard !dashboardConfigBusy else { return }
        let previousSelectedURL = configService.selectedConfig
        let previousSelectedPath = configService.selectedConfig?.path
        guard configService.chooseConfigDirectory() != nil else { return }

        let nextSelectedURL = configService.selectedConfig
        let previousCanonicalPath = previousSelectedURL?.standardizedFileURL.resolvingSymlinksInPath().path
        let nextCanonicalPath = nextSelectedURL?.standardizedFileURL.resolvingSymlinksInPath().path

        if processManager.isRunning,
           let nextSelectedURL,
           previousCanonicalPath != nextCanonicalPath
        {
            let validationFailure = await self.configValidationFailureDetails(configPath: nextSelectedURL.path)
            let currentCanonicalPath = self.configService.selectedConfig?.standardizedFileURL
                .resolvingSymlinksInPath().path
            guard currentCanonicalPath == nextCanonicalPath else { return }
            if let validationFailure {
                self.handleConfigValidationFailure(configPath: nextSelectedURL.path, details: validationFailure)
                if let previousSelectedURL {
                    configService.selectConfig(previousSelectedURL)
                }
                _ = self.syncSelectedConfigSelection(configService.selectedConfig)
                syncConfigDisplayState()
                return
            }
        }

        let nextSelectedPath = self.syncSelectedConfigSelection(configService.selectedConfig)
        syncConfigDisplayState()

        appendLog(level: "info", message: tr("log.config.loaded_count", configService.availableConfigs.count))
        await restartCoreIfNeededForConfigSwitch(previousPath: previousSelectedPath, nextPath: nextSelectedPath)
    }

    func selectConfigFile(named fileName: String, startIfStopped: Bool = false) async {
        guard !dashboardConfigBusy else { return }
        if (try? effectiveConfigTransaction.currentRecord()) != nil {
            let changes = (try? effectiveConfigTransaction.currentRecord())?.changes ?? []
            if startIfStopped {
                await selectDashboardConfiguration(fileName, changes: changes)
            } else {
                await applyDashboardConfiguration(baseName: fileName, changes: changes)
            }
            if let dashboardConfigError {
                appendLog(level: "error", message: dashboardConfigError)
            }
            return
        }
        let previousSelectedURL = configService.selectedConfig
        let previousSelectedPath = configService.selectedConfig?.path
        guard let matched = configService.availableConfigs.first(where: { $0.lastPathComponent == fileName }) else {
            appendLog(level: "error", message: tr("log.config.not_found", fileName))
            return
        }

        let previousCanonicalPath = previousSelectedURL?.standardizedFileURL.resolvingSymlinksInPath().path
        let targetCanonicalPath = matched.standardizedFileURL.resolvingSymlinksInPath().path

        if processManager.isRunning,
           previousCanonicalPath != targetCanonicalPath
        {
            let validationFailure = await self.configValidationFailureDetails(configPath: matched.path)
            let currentCanonicalPath = self.configService.selectedConfig?.standardizedFileURL
                .resolvingSymlinksInPath().path
            guard currentCanonicalPath == previousCanonicalPath else { return }
            if let validationFailure {
                self.handleConfigValidationFailure(configPath: matched.path, details: validationFailure)
                if let previousSelectedURL {
                    configService.selectConfig(previousSelectedURL)
                }
                _ = self.syncSelectedConfigSelection(configService.selectedConfig)
                syncConfigDisplayState()
                return
            }
        }

        configService.selectConfig(matched)
        let nextSelectedPath = self.syncSelectedConfigSelection(matched)
        syncConfigDisplayState()
        appendLog(level: "info", message: tr("log.config.selected", fileName))
        await restartCoreIfNeededForConfigSwitch(previousPath: previousSelectedPath, nextPath: nextSelectedPath)
        if startIfStopped, !isRemoteTarget, !isRuntimeRunning {
            await startCore(trigger: .manual)
        }
    }

    func importLocalConfigFile(dashboardErrors: Bool = false) {
        guard let configDirectory = ensureConfigDirectoryAvailable() else { return }

        self.prepareModalWindowPresentation()
        let panel = NSOpenPanel()
        self.configureModalWindow(panel)
        panel.title = tr("ui.quick.import_local_config")
        panel.directoryURL = configDirectory
        var allowedTypes: [UTType] = []
        if let yamlType = UTType(filenameExtension: "yaml") {
            allowedTypes.append(yamlType)
        }
        if let ymlType = UTType(filenameExtension: "yml"), !allowedTypes.contains(ymlType) {
            allowedTypes.append(ymlType)
        }
        if !allowedTypes.isEmpty {
            panel.allowedContentTypes = allowedTypes
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        guard let fileName = normalizedConfigFileName(sourceURL.lastPathComponent) else {
            let message = tr("log.config.import.invalid_filename", sourceURL.lastPathComponent)
            appendLog(level: "error", message: message)
            if dashboardErrors { dashboardConfigError = message }
            return
        }

        let targetURL = configDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard self.remoteConfigSubscriptions[fileName] == nil else {
            let message = uiLanguage == .zhHans ? "同名订阅已存在：\(fileName)" : "A subscription with this name already exists: \(fileName)"
            appendLog(level: "error", message: message)
            if dashboardErrors { dashboardConfigError = message }
            return
        }
        let isOverwrite = FileManager.default.fileExists(atPath: targetURL.path)
        if isOverwrite, fileName == selectedConfigName {
            let message = uiLanguage == .zhHans ? "不能覆盖当前基础配置，请使用其他文件名。" : "Cannot overwrite the active base configuration; use a different file name."
            appendLog(level: "error", message: message)
            if dashboardErrors { dashboardConfigError = message }
            return
        }
        guard !isOverwrite || self.confirmOverwriteConfig(named: fileName) else {
            appendLog(level: "info", message: tr("log.config.import.cancelled", fileName))
            return
        }

        do {
            let data = try Data(contentsOf: sourceURL)
            try writeConfigData(data, to: targetURL)

            self.removeRemoteConfigSubscription(for: fileName)
            appendLog(level: "info", message: tr("log.config.import_local.success", fileName))

            if isOverwrite, self.shouldAutoReloadCurrentConfig(updatedFileNames: [fileName]) {
                Task { [weak self] in await self?.reloadConfig() }
            }
        } catch {
            if dashboardErrors { dashboardConfigError = error.localizedDescription }
            appendLog(
                level: "error",
                message: tr("log.config.import_local.failed", fileName, error.localizedDescription))
        }
    }
}
