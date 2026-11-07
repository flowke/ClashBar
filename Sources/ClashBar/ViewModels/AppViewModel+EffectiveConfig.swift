import Foundation

@MainActor
extension AppViewModel {
    var effectiveConfigTransaction: EffectiveConfigTransaction {
        EffectiveConfigTransaction(
            configDirectory: workingDirectoryManager.configDirectoryURL,
            stateDirectory: workingDirectoryManager.stateDirectoryURL)
    }

    func refreshDashboardEffectiveConfig() {
        do {
            dashboardEffectiveRecord = try effectiveConfigTransaction.currentRecord()
        } catch {
            dashboardConfigError = error.localizedDescription
        }
    }

    func effectiveConfigURL(for baseName: String) -> URL? {
        guard let record = try? effectiveConfigTransaction.currentRecord(), record.baseName == baseName,
              let url = effectiveConfigTransaction.currentFile(record),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    @discardableResult
    func applyDashboardConfiguration(baseName: String, changes: [CustomRuleChange], replacementSource: Data? = nil,
                                     allowDisabled: Bool = false,
                                     precondition: () throws -> Void = {}) async -> Bool {
        guard !dashboardConfigBusy else { return false }
        guard !isCoreActionProcessing else {
            dashboardConfigError = uiLanguage == .zhHans ? "内核操作进行中，请稍后重试。" : "A core operation is in progress. Try again shortly."
            return false
        }
        guard !isRemoteTarget else {
            dashboardConfigError = "配置管理仅适用于本地核心。"
            return false
        }
        guard let source = configService.availableConfigs.first(where: { $0.lastPathComponent == baseName }) else {
            dashboardConfigError = "基础配置不存在。"
            return false
        }
        if let subscription = remoteConfigSubscriptions[baseName], !subscription.isEnabled, !allowDisabled {
            dashboardConfigError = uiLanguage == .zhHans ? "该订阅已停用。" : "This subscription is disabled."
            return false
        }
        dashboardConfigBusy = true
        dashboardConfigError = nil
        defer { dashboardConfigBusy = false }
        let previousURL = effectiveConfigURL(for: selectedConfigName) ?? configService.selectedConfig
        let running = processManager.isRunning
        let previousName = selectedConfigName
        let expectedTun = isTunEnabled
        guard !running || previousURL != nil else {
            dashboardConfigError = "无法确定当前生效配置，未应用新配置。"
            return false
        }
        do {
            let original = try Data(contentsOf: source)
            let data = try ConfigRuleMerger().merge(replacementSource ?? original, changes: changes)
            var sourceWritten = false
            let record = try await effectiveConfigTransaction.commit(
                data: data, baseName: baseName, changes: changes,
                validate: { [self] candidate in
                    try await processManager.validateConfig(configPath: candidate.path)
                },
                apply: { [self] candidate in
                    guard running else { return }
                    try await clientOrThrow().requestNoResponse(.putConfigs(force: false, path: candidate.path, payload: nil))
                    try await restoreTunAfterConfigReloadIfNeeded(expectedEnabled: expectedTun)
                },
                finalize: {
                    guard !self.isRemoteTarget, self.processManager.isRunning == running,
                          self.selectedConfigName == previousName else { throw CocoaError(.fileWriteFileExists) }
                    try precondition()
                    guard try Data(contentsOf: source) == original else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    guard let replacementSource else { return }
                    try replacementSource.write(to: source, options: .atomic)
                    sourceWritten = true
                },
                rollback: { [self] in
                    var sourceError: Error?
                    if sourceWritten {
                        do { try original.write(to: source, options: .atomic) }
                        catch { sourceError = error }
                    }
                    if running, let previousURL {
                        do {
                            try await clientOrThrow().requestNoResponse(.putConfigs(force: false, path: previousURL.path, payload: nil))
                            try await restoreTunAfterConfigReloadIfNeeded(expectedEnabled: expectedTun)
                        } catch {
                            if let sourceError {
                                throw EffectiveConfigTransactionError.rollbackFailed(sourceError.localizedDescription, error.localizedDescription)
                            }
                            throw error
                        }
                    }
                    if let sourceError { throw sourceError }
                })
            configService.selectConfig(source)
            _ = syncSelectedConfigSelection(source)
            syncConfigDisplayState()
            dashboardEffectiveRecord = record
            syncConfigSignatureSnapshotToMonitorBaseline()
            return true
        } catch {
            dashboardConfigError = error.localizedDescription
            return false
        }
    }

    func setDashboardSubscriptionEnabled(_ enabled: Bool, name: String) async {
        guard var subscription = remoteConfigSubscriptions[name], subscription.isEnabled != enabled else { return }
        if !enabled && selectedConfigName == name {
            guard let fallback = availableConfigFileNames.first(where: {
                $0 != name && (remoteConfigSubscriptions[$0]?.isEnabled ?? true)
            }) else {
                dashboardConfigError = uiLanguage == .zhHans ? "请先选择其他基础配置。" : "Select another base configuration first."
                return
            }
            let changes = (try? effectiveConfigTransaction.currentRecord())?.changes ?? []
            guard await applyDashboardConfiguration(baseName: fallback, changes: changes) else { return }
        }
        subscription.enabled = enabled
        remoteConfigSubscriptions[name] = subscription
        persistRemoteConfigSubscriptions()
        restartRemoteConfigBackgroundTasksIfNeeded()
        refreshRemoteConfigMenuStates()
    }

    @discardableResult
    func editDashboardSubscription(name: String, newName: String, urlString: String) async -> Bool {
        guard !dashboardConfigBusy, remoteConfigMenuState(for: name).phase != .refreshing else {
            dashboardConfigError = uiLanguage == .zhHans ? "配置正在处理中，请稍后重试。" : "The configuration is busy. Try again shortly."
            return false
        }
        guard let normalized = normalizedConfigFileName(newName) else {
            dashboardConfigError = uiLanguage == .zhHans ? "请输入有效的文件名。" : "Enter a valid file name."
            return false
        }
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              isSupportedRemoteConfigURL(url), let host = url.host, !host.isEmpty,
              remoteConfigSubscriptions[name] != nil else {
            dashboardConfigError = uiLanguage == .zhHans ? "请输入有效的订阅地址。" : "Enter a valid subscription URL."
            return false
        }
        dashboardConfigError = nil
        if normalized != name {
            await renameDashboardConfig(name, to: normalized)
            guard dashboardConfigError == nil, remoteConfigSubscriptions[normalized] != nil,
                  remoteConfigSubscriptions[name] == nil else {
                if dashboardConfigError == nil {
                    dashboardConfigError = uiLanguage == .zhHans ? "无法重命名配置。" : "Unable to rename the configuration."
                }
                return false
            }
        }
        guard let existing = remoteConfigSubscriptions[normalized] else { return false }
        remoteConfigSubscriptions[normalized] = RemoteConfigSubscription(
            urlString: url.absoluteString, autoUpdateEnabled: existing.autoUpdateEnabled,
            autoUpdateIntervalHours: existing.autoUpdateIntervalHours, lastUpdateCheckAt: existing.lastUpdateCheckAt,
            usage: existing.usage, enabled: existing.enabled)
        persistRemoteConfigSubscriptions()
        restartRemoteConfigBackgroundTasksIfNeeded()
        refreshRemoteConfigMenuStates()
        return true
    }

    func renameDashboardConfig(_ name: String, to newName: String) async {
        guard !dashboardConfigBusy, remoteConfigMenuState(for: name).phase != .refreshing,
              let directory = ensureConfigDirectoryAvailable(),
              let normalized = normalizedConfigFileName(newName), normalized != name else { return }
        let source = directory.appendingPathComponent(name)
        let target = directory.appendingPathComponent(normalized)
        let subscription = remoteConfigSubscriptions[name]
        do {
            guard !FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.copyItem(at: source, to: target)
            _ = configService.reloadConfigs()
            if let subscription { remoteConfigSubscriptions[normalized] = subscription }
            if name == selectedConfigName {
                let changes = (try? effectiveConfigTransaction.currentRecord())?.changes ?? []
                guard await applyDashboardConfiguration(baseName: normalized, changes: changes, allowDisabled: true) else {
                    remoteConfigSubscriptions[normalized] = nil
                    try? FileManager.default.removeItem(at: target)
                    _ = configService.reloadConfigs()
                    syncConfigDisplayState()
                    return
                }
            }
            try FileManager.default.removeItem(at: source)
            remoteConfigSubscriptions[name] = nil
            persistRemoteConfigSubscriptions()
            restartRemoteConfigBackgroundTasksIfNeeded()
            _ = configService.reloadConfigs()
            syncConfigDisplayState()
            syncConfigSignatureSnapshotToMonitorBaseline()
        } catch {
            dashboardConfigError = error.localizedDescription
            persistRemoteConfigSubscriptions()
            restartRemoteConfigBackgroundTasksIfNeeded()
            _ = configService.reloadConfigs()
            syncConfigDisplayState()
        }
    }

    func deleteDashboardConfig(_ name: String) async {
        guard !dashboardConfigBusy else { return }
        guard confirmDeleteConfig(named: name) else { return }
        if selectedConfigName == name {
            guard let fallback = availableConfigFileNames.first(where: {
                $0 != name && (remoteConfigSubscriptions[$0]?.isEnabled ?? true)
            }) else {
                dashboardConfigError = uiLanguage == .zhHans ? "请先添加并选择其他基础配置。" : "Add and select another base configuration first."
                return
            }
            let changes = (try? effectiveConfigTransaction.currentRecord())?.changes ?? []
            guard await applyDashboardConfiguration(baseName: fallback, changes: changes) else { return }
        }
        await deleteConfigFile(named: name, confirmed: true)
        syncConfigSignatureSnapshotToMonitorBaseline()
    }
}
