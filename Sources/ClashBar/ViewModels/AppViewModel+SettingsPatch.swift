import Foundation

@MainActor
extension AppViewModel {
    func cancelProxyPortRetry() {
        proxyPortRetryID = nil
        proxyPortRetryTask?.cancel()
        if isRetryingProxyPorts { proxyPortWarning = nil }
        isRetryingProxyPorts = false
    }

    func waitForProxyPortRetryToStop() async {
        let task = proxyPortRetryTask
        await task?.value
    }

    func retryProxyPorts() {
        guard !isRemoteTarget, isRuntimeRunning, proxyPortRetryID == nil else { return }
        do {
            startProxyPortRetry(try resolvedProxyPorts().patch)
        } catch {
            proxyPortWarning = error.localizedDescription
        }
    }

    func startProxyPortRetry(_ body: [String: ConfigPatchValue], attempts: Int = 10, interval: UInt64 = 1_000_000_000) {
        guard !isRemoteTarget, isRuntimeRunning, proxyPortRetryID == nil else { return }
        let id = UUID()
        proxyPortRetryID = id
        isRetryingProxyPorts = true
        proxyPortWarning = tr("app.settings.ports.retrying")
        let previousTask = proxyPortRetryTask
        proxyPortRetryTask = Task { [weak self] in
            await previousTask?.value
            guard let self else { return }
            defer {
                if self.proxyPortRetryID == id {
                    self.proxyPortRetryID = nil
                    self.proxyPortRetryTask = nil
                    self.isRetryingProxyPorts = false
                }
            }
            let previousPorts = self.currentSystemProxyPortsFromState()
            var lastMessage: String?
            for _ in 0..<attempts {
                do {
                    try await Task.sleep(nanoseconds: interval)
                    try Task.checkCancellation()
                    guard self.proxyPortRetryID == id, self.isRuntimeRunning, !self.isRemoteTarget else { return }
                    let config: ConfigSnapshot = try await self.clientOrThrow().request(.getConfigs)
                    try Task.checkCancellation()
                    guard self.proxyPortRetryID == id else { return }
                    let missing = ProxyPortValues.mismatchedPatch(in: body, actual: ProxyPortValues(config: config))
                    if !missing.isEmpty {
                        try await self.clientOrThrow().requestNoResponse(.patchConfigs(body: missing.mapValues(\.jsonValue)))
                        try Task.checkCancellation()
                    }
                    try await self.verifyRuntimeProxyPorts(body)
                    try Task.checkCancellation()
                    guard self.proxyPortRetryID == id else { return }
                    await self.refreshFromAPI(includeSlowCalls: false)
                    guard !Task.isCancelled, self.proxyPortRetryID == id else { return }
                    await self.reconcileEditableSettingsWithRuntimeConfig()
                    guard !Task.isCancelled, self.proxyPortRetryID == id else { return }
                    await self.syncSystemProxyPortIfNeeded(shouldSync: true, previousPorts: previousPorts)
                    self.appendLog(level: "info", message: self.tr("app.settings.ports.retry_succeeded"))
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, self.proxyPortRetryID == id else { return }
                    lastMessage = error.localizedDescription
                    self.proxyPortWarning = self.tr("app.settings.ports.retrying")
                }
            }
            guard !Task.isCancelled, self.proxyPortRetryID == id else { return }
            self.proxyPortWarning = lastMessage ?? self.tr("app.settings.ports.retry_failed")
            self.appendLog(level: "error", message: self.proxyPortWarning ?? "")
        }
    }

    func resolvedProxyPorts(configURL: URL? = nil) throws -> ProxyPortValues {
        if let manualProxyPorts { return manualProxyPorts }
        guard let url = configURL ?? configService.selectedConfig else { throw ProxyPortError.missingConfig }
        return try ProxyPortValues.fromConfig(Data(contentsOf: url))
    }

    func applyRuntimeProxyPorts(configURL: URL) async throws {
        let ports = try resolvedProxyPorts(configURL: configURL)
        try await clientOrThrow().requestNoResponse(.patchConfigs(body: ports.patch.mapValues(\.jsonValue)))
        try await verifyRuntimeProxyPorts(ports.patch)
    }

    func verifyRuntimeProxyPorts(_ body: [String: ConfigPatchValue]) async throws {
        let keys = ["port", "socks-port", "mixed-port", "redir-port", "tproxy-port"]
        guard keys.contains(where: { body[$0] != nil }) else { return }
        let config: ConfigSnapshot = try await clientOrThrow().request(.getConfigs)
        try Task.checkCancellation()
        if let mismatch = ProxyPortValues.firstMismatch(in: body, actual: ProxyPortValues(config: config)) {
            let message = tr("app.settings.error.port_not_applied", mismatch.key, mismatch.expected, mismatch.actual)
            proxyPortWarning = message
            throw ProxyPortRuntimeError(message: message)
        }
        proxyPortWarning = nil
    }

    func showProxyPortValues(_ ports: ProxyPortValues) {
        suppressSettingsPersistence = true
        settingsPort = String(ports.port)
        settingsSocksPort = String(ports.socksPort)
        settingsMixedPort = String(ports.mixedPort)
        settingsRedirPort = String(ports.redirPort)
        settingsTProxyPort = String(ports.tproxyPort)
        suppressSettingsPersistence = false
    }

    func followConfigProxyPorts() async {
        guard !isRemoteTarget, let url = configService.selectedConfig else { return }
        cancelProxyPortRetry()
        await waitForProxyPortRetryToStop()
        do {
            let ports = try ProxyPortValues.fromConfig(Data(contentsOf: url))
            cancelProxyPortsAutoSave()
            if isRuntimeRunning {
                guard await patchConfigBody(ports.patch, syncingKey: "ports", successMessage: tr("app.settings.saved.ports")) else { return }
            } else {
                showProxyPortValues(ports)
            }
            manualProxyPorts = nil
            defaults.removeObject(forKey: "clashbar.settings.proxyPorts.manual.v1")
        } catch {
            settingsErrorMessage = error.localizedDescription
        }
    }

    func effectiveMixedPort() -> Int {
        if self.mixedPort > 0 {
            return self.mixedPort
        }

        let trimmed = self.settingsMixedPort.trimmed
        if let value = Int(trimmed), (1...65535).contains(value) {
            return value
        }

        return 7890
    }

    func applyEditableSettingsSnapshotToUI(_ snapshot: EditableSettingsSnapshot) {
        suppressSettingsPersistence = true
        currentMode = snapshot.mode
        settingsAllowLan = snapshot.allowLan
        settingsIPv6 = snapshot.ipv6
        settingsTCPConcurrent = snapshot.tcpConcurrent
        isTunEnabled = snapshot.tunEnabled
        settingsLogLevel = snapshot.logLevel
        settingsPort = snapshot.port
        settingsSocksPort = snapshot.socksPort
        settingsMixedPort = snapshot.mixedPort
        settingsRedirPort = snapshot.redirPort
        settingsTProxyPort = snapshot.tproxyPort
        suppressSettingsPersistence = false
    }

    func applySettingBool(key: String, value: Bool) async {
        await self.patchSingleConfig(key, value: .bool(value))
    }

    func patchSingleConfig(_ key: String, value: ConfigPatchValue) async {
        _ = await self.patchConfigBody(
            [key: value],
            syncingKey: key,
            successMessage: tr("app.settings.saved.single_key", key))
    }

    @discardableResult
    func patchConfigBody(
        _ body: [String: ConfigPatchValue],
        syncingKey: String,
        successMessage: String,
        syncSystemProxyPort: Bool = true) async -> Bool
    {
        self.cancelProxyPortsAutoSave()
        settingsFeedbackClearTask?.cancel()
        settingsFeedbackClearTask = nil
        settingsSyncingKey = syncingKey
        settingsErrorMessage = nil
        settingsSavedMessage = nil
        defer { settingsSyncingKey = nil }
        let shouldSyncSystemProxyPort = syncSystemProxyPort && !self.isRemoteTarget && body.keys.contains { key in
            key == "mixed-port" || key == "port" || key == "socks-port"
        }
        let previousSystemProxyPorts =
            await previousSystemProxyPortsForSyncIfNeeded(shouldSync: shouldSyncSystemProxyPort)

        let patchKeysDescription = body.keys.sorted().joined(separator: ", ")
        do {
            ensureAPIClient()
            appendLog(level: "info", message: "PATCH /configs [\(patchKeysDescription)]")
            try await self.clientOrThrow().requestNoResponse(.patchConfigs(body: body.mapValues(\.jsonValue)))
            guard !Task.isCancelled else { return false }
            try await verifyRuntimeProxyPorts(body)
            appendLog(level: "info", message: "PATCH /configs succeeded [\(patchKeysDescription)]")
            await refreshFromAPI(includeSlowCalls: false)
            await self.reconcileEditableSettingsWithRuntimeConfig()
            settingsSavedMessage = successMessage
            self.scheduleSettingsFeedbackAutoClearIfNeeded(message: successMessage)
            await self.syncSystemProxyPortIfNeeded(
                shouldSync: shouldSyncSystemProxyPort,
                previousPorts: previousSystemProxyPorts)
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            appendLog(
                level: "error",
                message: "PATCH /configs failed [\(patchKeysDescription)]: \(error.localizedDescription)")
            let message = tr("app.settings.error.save_failed", syncingKey, error.localizedDescription)
            if self.isOverlaySyncingKey(syncingKey) {
                appendLog(level: "error", message: message)
            } else {
                settingsErrorMessage = message
            }
            settingsSavedMessage = nil
            await refreshFromAPI(includeSlowCalls: false)
            await self.reconcileEditableSettingsWithRuntimeConfig()
            if error is ProxyPortRuntimeError, isOverlaySyncingKey(syncingKey) {
                if syncingKey == "start-overlay" || syncingKey == "restart-overlay" || syncingKey == "app-launch-overlay" {
                    startProxyPortRetry(body.filter { ["port", "socks-port", "mixed-port", "redir-port", "tproxy-port"].contains($0.key) })
                }
                return true
            }
            return false
        }
    }

    func isOverlaySyncingKey(_ syncingKey: String) -> Bool {
        syncingKey.hasSuffix("-overlay")
    }

    func scheduleDeferredEditableSettingsOverlaySync() {
        self.deferredEditableSettingsOverlayTask?.cancel()
        self.deferredEditableSettingsOverlayTask = Task { [weak self] in
            guard let self else { return }

            for _ in 0..<120 {
                if Task.isCancelled {
                    return
                }
                guard self.isRuntimeRunning else { return }
                if await self.applyDeferredEditableSettingsOverlayIfPossible() {
                    self.deferredEditableSettingsOverlayTask = nil
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
            }

            self.deferredEditableSettingsOverlayTask = nil
        }
    }

    func applyDeferredEditableSettingsOverlayIfPossible() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard let deferred = self.deferredEditableSettingsOverlay else { return true }
        guard await self.isCoreAPIReachableForOverlaySync() else { return false }
        guard !Task.isCancelled else { return false }

        let applied = await self.applyEditableSettingsOverlay(
            deferred.snapshot,
            syncingKey: deferred.syncingKey,
            successMessage: "")
        if applied {
            self.deferredEditableSettingsOverlay = nil
        }
        return applied
    }

    private func isCoreAPIReachableForOverlaySync() async -> Bool {
        do {
            let client = try self.clientOrThrow()
            let _: VersionInfo = try await client.request(.version)
            return true
        } catch {
            return false
        }
    }

    func scheduleSettingsFeedbackAutoClearIfNeeded(message: String) {
        guard message.trimmedNonEmpty != nil else { return }

        settingsFeedbackClearTask?.cancel()
        settingsFeedbackClearTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }

            guard let self else { return }
            if self.settingsSavedMessage == message {
                self.settingsSavedMessage = nil
            }
        }
    }

    func clientOrThrow() throws -> MihomoAPIService {
        if apiClient == nil {
            ensureAPIClient()
        }
        if let apiClient {
            return apiClient
        }
        throw APIError.invalidURL
    }

    private func previousSystemProxyPortsForSyncIfNeeded(shouldSync: Bool) async -> SystemProxyPorts? {
        guard shouldSync, isSystemProxyEnabled else { return nil }
        do {
            let config: ConfigSnapshot = try await self.clientOrThrow().request(.getConfigs)
            return systemProxyPorts(from: config)
        } catch {
            return currentSystemProxyPortsFromState()
        }
    }

    func syncSystemProxyPortIfNeeded(shouldSync: Bool, previousPorts: SystemProxyPorts?) async {
        guard shouldSync, isSystemProxyEnabled else { return }

        do {
            let target = try await resolveSystemProxyTargetFromRuntimeConfig()
            let stillOwnsProxy = self.systemProxyStillMatchesExpectedTarget()
            self.rememberSystemProxyTarget(host: target.host, ports: target.ports)
            guard stillOwnsProxy else {
                self.checkSystemProxyConfiguration()
                return
            }
            try await applySystemProxy(enabled: true, host: target.host, ports: target.ports)
            try await self.applyCurrentSystemProxyExceptionsIfNeeded()
            self.checkSystemProxyConfiguration()
            guard self.systemProxyStatus == .active else { return }
            appendLog(level: "info", message: tr("log.system_proxy.port_synced", target.ports.primaryPort ?? 0))

            if let previousPorts, previousPorts != target.ports {
                await closeAllConnections()
            }
        } catch {
            appendLog(level: "error", message: tr("log.system_proxy.port_sync_failed", systemProxyErrorMessage(error)))
            await self.refreshSystemProxyHelperStatus()
        }
    }

    func applyBooleanSetting(
        _ keyPath: ReferenceWritableKeyPath<AppViewModel, Bool>,
        configKey: String,
        value: Bool) async
    {
        await self.applySettingBool(key: configKey, value: value)
    }

    func reconcileEditableSettingsWithRuntimeConfig() async {
        do {
            let config = try await self.fetchRuntimeConfigSnapshot()
            let incoming = EditableSettingsSnapshot(config: config)
            self.applyEditableSettingsSnapshotToUI(incoming)
            self.lastSyncedEditableSettings = incoming
            self.persistEditableSettingsSnapshot()
        } catch {
            appendLog(level: "error", message: "Settings reconciliation failed: \(error.localizedDescription)")
        }
    }

    var proxyPortFields: [SettingsPortField] {
        [
            SettingsPortField(key: "port", value: settingsPort),
            SettingsPortField(key: "socks-port", value: settingsSocksPort),
            SettingsPortField(key: "mixed-port", value: settingsMixedPort),
            SettingsPortField(key: "redir-port", value: settingsRedirPort),
            SettingsPortField(key: "tproxy-port", value: settingsTProxyPort),
        ]
    }

    func tunOverlayPatchBody(enabled: Bool) async -> [String: ConfigPatchValue] {
        var tunBody: [String: ConfigPatchValue] = ["enable": .bool(enabled)]
        if enabled, let stack = await self.preferredTunStack() {
            tunBody["stack"] = .string(stack)
        }
        return tunBody
    }

    func validatedPortPatchBody(
        fields: [SettingsPortField],
        errorMessageKey: String,
        skipEmptyValues: Bool) -> [String: ConfigPatchValue]?
    {
        var body: [String: ConfigPatchValue] = [:]

        for field in fields {
            let trimmedValue = field.value.trimmed
            if skipEmptyValues, trimmedValue.isEmpty {
                continue
            }

            guard let intValue = Int(trimmedValue), (0...65535).contains(intValue) else {
                settingsErrorMessage = tr(errorMessageKey, field.key)
                settingsSavedMessage = nil
                return nil
            }

            body[field.key] = .int(intValue)
        }

        return body
    }

    func syncEditableFields<Value: Equatable>(
        from previous: EditableSettingsSnapshot,
        to incoming: EditableSettingsSnapshot,
        fields: [(ReferenceWritableKeyPath<AppViewModel, Value>, KeyPath<EditableSettingsSnapshot, Value>)])
    {
        for (stateKeyPath, snapshotKeyPath) in fields {
            guard self[keyPath: stateKeyPath] == previous[keyPath: snapshotKeyPath] else { continue }
            self[keyPath: stateKeyPath] = incoming[keyPath: snapshotKeyPath]
        }
    }
}
