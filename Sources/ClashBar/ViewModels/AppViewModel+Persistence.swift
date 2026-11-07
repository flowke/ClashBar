import Foundation

@MainActor
extension AppViewModel {
    func resolveSelectedConfigPath() async -> String? {
        do {
            if let record = try effectiveConfigTransaction.currentRecord() {
                guard let source = configService.availableConfigs.first(where: { $0.lastPathComponent == record.baseName }),
                      let effective = effectiveConfigTransaction.currentFile(record),
                      FileManager.default.fileExists(atPath: effective.path) else {
                    dashboardConfigError = "已保存的生效配置或基础配置不存在。"
                    return nil
                }
                configService.selectConfig(source)
                _ = self.syncSelectedConfigSelection(source)
                self.syncConfigDisplayState()
                dashboardEffectiveRecord = record
                return effective.path
            }
        } catch {
            dashboardConfigError = error.localizedDescription
            return nil
        }
        if let path = self.applySelectedConfig(configService.selectedConfig) {
            return path
        }

        if let selectedName = defaults.string(forKey: selectedConfigKey),
           let selected = configService.availableConfigs.first(where: { $0.lastPathComponent == selectedName })
        {
            configService.selectConfig(selected)
            return self.applySelectedConfig(selected)
        }

        if let legacySelectedPath = defaults.string(forKey: legacySelectedConfigKey) {
            let legacyName = URL(fileURLWithPath: legacySelectedPath).lastPathComponent
            defaults.set(legacyName, forKey: selectedConfigKey)
            defaults.removeObject(forKey: legacySelectedConfigKey)
            if let selected = configService.availableConfigs.first(where: { $0.lastPathComponent == legacyName }) {
                configService.selectConfig(selected)
                return self.applySelectedConfig(selected)
            }
        }

        _ = configService.reloadConfigs()
        return self.applySelectedConfig(configService.selectedConfig)
    }

    private func applySelectedConfig(_ selected: URL?) -> String? {
        guard let selected else { return nil }
        let selectedPath = self.syncSelectedConfigSelection(selected)
        self.syncConfigDisplayState()
        guard let selectedPath else { return nil }
        return self.effectiveConfigURL(for: selected.lastPathComponent)?.path ?? selectedPath
    }

    func restoreSavedConfigDirectory() {
        configService.setConfigDirectory(workingDirectoryManager.configDirectoryURL)
        let record = try? effectiveConfigTransaction.currentRecord()
        let preferredName = record?.baseName ?? defaults.string(forKey: selectedConfigKey)
        if let preferredName,
           let preferred = configService.availableConfigs.first(where: { $0.lastPathComponent == preferredName }) {
            configService.selectConfig(preferred)
        }
        dashboardEffectiveRecord = record
        if let selected = configService.selectedConfig {
            _ = self.syncSelectedConfigSelection(selected)
        }
        self.syncConfigDisplayState()
    }

    func restoreLastSuccessfulConfigIfAvailable() {
        if (try? effectiveConfigTransaction.currentRecord()) != nil { return }
        guard let lastPath = defaults.string(forKey: lastSuccessfulConfigPathKey), !lastPath.isEmpty else { return }
        let candidate = URL(fileURLWithPath: lastPath)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return }
        guard let matched = configService.availableConfigs.first(where: {
            $0.standardizedFileURL.resolvingSymlinksInPath().path == candidate.standardizedFileURL
                .resolvingSymlinksInPath().path
        }) else {
            return
        }
        configService.selectConfig(matched)
        _ = self.syncSelectedConfigSelection(matched)
        self.syncConfigDisplayState()
    }

    func syncConfigDisplayState() {
        configDirectoryPath = configService.configDirectory?.path ?? "-"
        availableConfigFileNames = configService.availableConfigs.map(\.lastPathComponent)
        if selectedConfigName == "-", let first = availableConfigFileNames.first {
            selectedConfigName = first
        }
        self.pruneSSIDStrategyRulesIfNeeded()
        self.pruneRemoteConfigSubscriptionsIfNeeded()
        self.refreshRemoteConfigMenuStates()
    }

    func ensureAPIClient() {
        if let apiClient {
            apiClient.updateCredentials(controller: controller, secret: controllerSecret)
        } else {
            apiClient = MihomoAPIService(controller: controller, secret: controllerSecret)
        }
    }

    func persistEditableSettingsSnapshot() {
        guard !suppressSettingsPersistence else { return }
        guard !self.isRemoteTarget else { return }
        self.encodeToDefaults(currentEditableSettingsSnapshot(), key: editableSettingsSnapshotKey)
    }

    func loadPersistedEditableSettingsSnapshot() -> EditableSettingsSnapshot? {
        self.decodeFromDefaults(EditableSettingsSnapshot.self, key: editableSettingsSnapshotKey)
    }

    func persistSystemProxyExceptions() {
        self.encodeToDefaults(self.lastSavedSystemProxyExceptions, key: systemProxyExceptionsKey)
    }

    func loadPersistedPinnedProxyGroupName() -> String? {
        self.defaults.string(forKey: self.pinnedProxyGroupNameKey)?.trimmedNonEmpty
    }

    func persistPinnedProxyGroupName() {
        guard let pinnedProxyGroupName = self.pinnedProxyGroupName?.trimmedNonEmpty else {
            self.defaults.removeObject(forKey: self.pinnedProxyGroupNameKey)
            return
        }

        self.defaults.set(pinnedProxyGroupName, forKey: self.pinnedProxyGroupNameKey)
    }

    func decodeFromDefaults<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func encodeToDefaults(_ value: some Encodable, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    func loadPersistedSystemProxyExceptions() -> [String]? {
        guard let values = self.decodeFromDefaults([String].self, key: systemProxyExceptionsKey) else { return nil }
        return self.normalizedSystemProxyExceptionValues(values)
    }

    func loadPersistedUILanguage() -> AppLanguage {
        if let raw = defaults.string(forKey: uiLanguageKey),
           let language = AppLanguage(rawValue: raw)
        {
            return language
        }
        defaults.set(AppLanguage.zhHans.rawValue, forKey: uiLanguageKey)
        return .zhHans
    }

    func loadPersistedAppearanceMode() -> AppAppearanceMode {
        if let raw = defaults.string(forKey: appearanceModeKey),
           let mode = AppAppearanceMode(rawValue: raw)
        {
            return mode
        }
        defaults.set(AppAppearanceMode.system.rawValue, forKey: appearanceModeKey)
        return .system
    }

    func loadPersistedAppTheme() -> AppTheme {
        if let raw = defaults.string(forKey: appThemeKey),
           let theme = AppTheme(rawValue: raw)
        {
            return theme
        }
        defaults.set(AppTheme.sage.rawValue, forKey: appThemeKey)
        return .sage
    }

    func loadPersistedRemoteConfigSubscriptions() -> [String: RemoteConfigSubscription] {
        if let subscriptions = self.decodeFromDefaults(
            [String: RemoteConfigSubscription].self,
            key: remoteConfigSubscriptionsKey)
        {
            var result: [String: RemoteConfigSubscription] = [:]
            for (fileName, sub) in subscriptions {
                guard let normalizedName = normalizedConfigFileName(fileName), normalizedName == fileName else {
                    continue
                }
                guard URL(string: sub.urlString).map({ isSupportedRemoteConfigURL($0) }) == true else { continue }
                result[normalizedName] = sub
            }
            return result
        }

        let v1 = self.loadPersistedRemoteConfigSources()
        guard !v1.isEmpty else { return [:] }

        var migrated: [String: RemoteConfigSubscription] = [:]
        for (fileName, urlString) in v1 {
            migrated[fileName] = RemoteConfigSubscription(
                urlString: urlString,
                autoUpdateEnabled: false,
                autoUpdateIntervalHours: RemoteConfigSubscription.defaultAutoUpdateIntervalHours,
                lastUpdateCheckAt: nil)
        }
        self.encodeToDefaults(migrated, key: remoteConfigSubscriptionsKey)
        defaults.removeObject(forKey: remoteConfigSourcesKey)
        return migrated
    }

    func persistRemoteConfigSubscriptions() {
        self.encodeToDefaults(remoteConfigSubscriptions, key: remoteConfigSubscriptionsKey)
    }

    func pruneRemoteConfigSubscriptionsIfNeeded() {
        let availableNames = Set(availableConfigFileNames)
        let filtered = remoteConfigSubscriptions.filter { availableNames.contains($0.key) }
        guard filtered.count != remoteConfigSubscriptions.count else { return }
        remoteConfigSubscriptions = filtered
        self.persistRemoteConfigSubscriptions()
        self.restartRemoteConfigBackgroundTasksIfNeeded()
    }

    func loadPersistedRemoteConfigSources() -> [String: String] {
        guard let stored = defaults.dictionary(forKey: remoteConfigSourcesKey) as? [String: String] else {
            return [:]
        }

        var result: [String: String] = [:]
        for (fileName, urlString) in stored {
            guard let normalizedName = normalizedConfigFileName(fileName), normalizedName == fileName else { continue }
            guard let url = URL(string: urlString), isSupportedRemoteConfigURL(url) else { continue }
            result[normalizedName] = url.absoluteString
        }
        return result
    }

    func loadPersistedSSIDStrategyRules() -> [SSIDStrategyRule] {
        let rules = self.decodeFromDefaults([SSIDStrategyRule].self, key: ssidStrategyRulesKey) ?? []
        return SSIDStrategyRule.normalized(rules)
    }

    func persistSSIDStrategyRules(_ rules: [SSIDStrategyRule]) {
        self.encodeToDefaults(SSIDStrategyRule.normalized(rules), key: ssidStrategyRulesKey)
    }

    func pruneSSIDStrategyRulesIfNeeded() {
        guard self.configService.configDirectory != nil else { return }

        let validConfigNames = Set(self.availableConfigFileNames.map(\.trimmed))
        let nextRules = SSIDStrategyRule.normalized(self.ssidStrategyRules).filter {
            validConfigNames.contains($0.configFileName)
        }
        guard nextRules != self.ssidStrategyRules else { return }

        self.ssidStrategyRules = nextRules
        self.persistSSIDStrategyRules(nextRules)
    }
}

extension AppViewModel {
    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = self.launchAtLoginService.isEnabled
    }

    func applyLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginErrorMessage = nil

        do {
            try self.launchAtLoginService.setEnabled(enabled)
            launchAtLoginEnabled = self.launchAtLoginService.isEnabled
        } catch {
            launchAtLoginEnabled = self.launchAtLoginService.isEnabled
            launchAtLoginErrorMessage = self.launchAtLoginMessage(for: error)
            appendLog(level: "error", message: tr("log.launch_at_login.toggle_failed", error.localizedDescription))
        }
    }

    private func launchAtLoginMessage(for error: Error) -> String {
        guard let launchError = error as? AppLaunchServiceError else {
            return error.localizedDescription
        }

        switch launchError {
        case .unsupportedEnvironment:
            return tr("app.launch_at_login.error.unsupported_environment")
        case .requiresApproval:
            return tr("app.launch_at_login.error.requires_approval")
        case let .registrationFailed(message):
            return tr("app.launch_at_login.error.register_failed", message)
        case let .unregistrationFailed(message):
            return tr("app.launch_at_login.error.unregister_failed", message)
        }
    }
}
