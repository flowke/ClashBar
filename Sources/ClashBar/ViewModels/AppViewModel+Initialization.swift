import Foundation

@MainActor
extension AppViewModel {
    func configureManagedProcessCallbacks() {
        self.refreshManagedCoreMetadata()
        if let managedProcess = self.processManager as? MihomoProcessManager {
            managedProcess.onLog = { [weak self] line in
                Task { @MainActor in
                    guard self?.isRemoteTarget != true else { return }
                    self?.appendMihomoLog(level: "info", message: line)
                }
            }
            managedProcess.onTermination = { [weak self] code in
                Task { @MainActor in
                    guard self?.isRemoteTarget != true else { return }
                    self?.cancelCoreBootstrap()
                    let message = self?.tr("log.process.terminated", code) ?? ""
                    self?.statusText = "Failed"
                    self?.apiStatus = .failed
                    self?.resetTrafficPresentation()
                    self?.appendLog(level: "error", message: message)
                    self?.cancelPolling()
                    if let self, !message.isEmpty {
                        self.statusItemBanner = StatusItemBanner(
                            symbolName: "exclamationmark.triangle.fill",
                            title: self.tr("app.core.alert.process_terminated.title"),
                            primaryDetail: message,
                            secondaryDetail: nil)
                    }
                }
            }
        }
    }

    func refreshManagedCoreMetadata() {
        guard !self.isRemoteTarget else { return }

        let detectedPath = self.processManager.detectedBinaryPath
        let path = detectedPath ?? "-"
        if self.mihomoBinaryPath != path { self.mihomoBinaryPath = path }
        let available = detectedPath != nil
        if self.isMihomoCoreAvailable != available { self.isMihomoCoreAvailable = available }

        guard available, self.version == "-" else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let detectedVersion = await self.processManager.detectedBinaryVersion() else { return }
            guard self.version == "-" else { return }
            self.version = detectedVersion
        }
    }

    func bootstrapDirectoriesAndLogs() {
        do {
            try self.workingDirectoryManager.bootstrapDirectories()
            ensureLogFileExists()
            seedBundledConfigIfNeeded()
        } catch {
            appendLog(level: "error", message: tr("log.working_dir_init_failed", error.localizedDescription))
        }
    }

    func startAgentRuleService() {
        do {
            let socket = AgentRuleSocket(stateDirectory: workingDirectoryManager.stateDirectoryURL) { [weak self] request in
                guard let self else {
                    return .failure("unavailable", "ClashBar is no longer available.")
                }
                return await self.handleAgentRuleRequest(request)
            }
            try socket.start()
            self.agentRuleSocket = socket
        } catch {
            appendLog(level: "error", message: "Agent rule service could not start: \(error.localizedDescription)")
        }
    }

    func start() {
        guard !self.didStart else { return }
        self.didStart = true
        self.bootstrapDirectoriesAndLogs()
        self.startCoreDirectoryMonitoring()
        self.performDeferredInitialization()
        self.startAgentRuleService()
    }

    func startCoreDirectoryMonitoring() {
        guard self.coreDirectoryMonitor == nil else { return }
        self.coreDirectoryMonitor = ConfigDirectoryMonitor(
            directoryURL: self.workingDirectoryManager.coreDirectoryURL,
            selectedFileURL: self.workingDirectoryManager.managedMihomoBinaryURL)
        { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.coreDirectoryMonitor?.updateSelectedFile(self.workingDirectoryManager.managedMihomoBinaryURL)
                self.refreshManagedCoreMetadata()
            }
        }
        self.refreshManagedCoreMetadata()
    }

    private func performDeferredInitialization() {
        self.systemProxyExpectedTarget = self.decodeFromDefaults(SystemProxyTarget.self, key: self.systemProxyTargetKey)
        self.startSystemProxyMonitoring()
        restoreSavedConfigDirectory()
        restoreLastSuccessfulConfigIfAvailable()
        self.remoteConfigSubscriptions = loadPersistedRemoteConfigSubscriptions()
        pruneRemoteConfigSubscriptionsIfNeeded()
        restartRemoteConfigBackgroundTasksIfNeeded()
        self.pinnedProxyGroupName = self.loadPersistedPinnedProxyGroupName()
        self.ssidStrategyRules = loadPersistedSSIDStrategyRules()
        self.pruneSSIDStrategyRulesIfNeeded()
        self.remoteMachineStore.resetActiveTarget()
        if let configPath = self.configService.selectedConfig?.path {
            _ = self.applyExternalControllerFromSelectedConfigFile(configPath: configPath)
        } else {
            self.refreshControllerUIURL()
        }
        manualProxyPorts = decodeFromDefaults(ProxyPortValues.self, key: "clashbar.settings.proxyPorts.manual.v1")
        if let persisted = loadPersistedEditableSettingsSnapshot() {
            applyEditableSettingsSnapshotToUI(persisted)
            self.preserveLocalSettingsOnNextSync = true
            self.pendingAppLaunchOverlaySettings = persisted
        }
        if let ports = try? resolvedProxyPorts() {
            showProxyPortValues(ports)
        }
        let persistedSystemProxyExceptions = loadPersistedSystemProxyExceptions() ?? Self.defaultSystemProxyExceptions
        self.replaceSystemProxyExceptionsDraft(with: persistedSystemProxyExceptions)
        self.lastSavedSystemProxyExceptions = self.normalizedSystemProxyExceptionValues(persistedSystemProxyExceptions)

        self.startupRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshFromAPI(includeSlowCalls: true)
            await self.applyPendingAppLaunchSettingsOverlayIfNeeded()
            self.seedCoreFeatureRecoveryFromPersistedQuitState()
            if self.hasSystemProxyOpenIntent {
                await self.refreshSystemProxyHelperStatus()
                await self.refreshSystemProxyStatus()
                await self.ensureSystemProxyConsistencyOnFirstLaunchIfNeeded()
            } else {
                self.resetSystemProxyObservedState()
                self.didCheckSystemProxyConsistencyOnLaunch = true
            }
        }

        self.startConfigDirectoryMonitoringIfNeeded()
        if self.autoStartCore {
            if !self.shouldDeferAutoStartForMissingManagedCore() {
                self.autoStartTask = Task { [weak self] in
                    await self?.attemptAutoStartIfNeeded()
                }
            }
        }

        self.refreshSSIDStrategyState(requestAuthorizationIfNeeded: self.ssidStrategyEnabled)
        self.updateNetworkReachabilityMonitoringState()
        self.refreshMenuBarDisplaySnapshotIfNeeded()
    }
}

extension AppViewModel {
    static func resolveBundledMihomoCoreFlag() -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "ClashBarBundlesMihomoCore") else {
            return true
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return NSString(string: string).boolValue
        }
        return true
    }

    func hasInstalledManagedMihomoCore() -> Bool {
        FileManager.default.fileExists(atPath: workingDirectoryManager.managedMihomoBinaryURL.path)
    }

    func shouldDeferAutoStartForMissingManagedCore() -> Bool {
        !bundlesMihomoCore && !self.hasInstalledManagedMihomoCore()
    }

    func coreErrorMessage(_ error: Error) -> String {
        if let binaryResolutionError = error as? MihomoBinaryResolutionError {
            switch binaryResolutionError {
            case let .binaryNotFound(expectedDirectory):
                return tr("app.core.error.binary_not_found", expectedDirectory)
            }
        }

        return error.localizedDescription
    }
}
