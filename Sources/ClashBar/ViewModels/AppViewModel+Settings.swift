import Foundation

@MainActor
extension AppViewModel {
    enum EditableCoreSetting: String, CaseIterable, Identifiable {
        case allowLan = "allow-lan"
        case ipv6
        case tcpConcurrent = "tcp-concurrent"
        case logLevel = "log-level"

        var id: String {
            self.rawValue
        }

        var configKey: String {
            self.rawValue
        }
    }

    private func boolStateKeyPath(for setting: EditableCoreSetting) -> ReferenceWritableKeyPath<AppViewModel, Bool>? {
        switch setting {
        case .allowLan:
            \.settingsAllowLan
        case .ipv6:
            \.settingsIPv6
        case .tcpConcurrent:
            \.settingsTCPConcurrent
        case .logLevel:
            nil
        }
    }

    private func stringStateKeyPath(for setting: EditableCoreSetting)
    -> ReferenceWritableKeyPath<AppViewModel, String>? {
        switch setting {
        case .logLevel:
            \.settingsLogLevel
        case .allowLan, .ipv6, .tcpConcurrent:
            nil
        }
    }

    func boolValue(for setting: EditableCoreSetting) -> Bool {
        guard let keyPath = self.boolStateKeyPath(for: setting) else {
            assertionFailure("Setting \(setting.configKey) does not store a Bool")
            return false
        }
        return self[keyPath: keyPath]
    }

    func stringValue(for setting: EditableCoreSetting) -> String {
        guard let keyPath = self.stringStateKeyPath(for: setting) else {
            assertionFailure("Setting \(setting.configKey) does not store a String")
            return ""
        }
        return self[keyPath: keyPath]
    }

    func applyEditableCoreSetting(_ setting: EditableCoreSetting, to value: Bool) async {
        guard let keyPath = self.boolStateKeyPath(for: setting) else {
            assertionFailure("Setting \(setting.configKey) does not accept Bool updates")
            return
        }
        await self.applyBooleanSetting(keyPath, configKey: setting.configKey, value: value)
    }

    func applyEditableCoreSetting(_ setting: EditableCoreSetting, to value: String) async {
        guard self.stringStateKeyPath(for: setting) != nil else {
            assertionFailure("Setting \(setting.configKey) does not accept String updates")
            return
        }

        let normalized = value.trimmed
        if setting == .logLevel, ConfigLogLevel(rawValue: normalized) == nil {
            settingsErrorMessage = tr("app.settings.error.invalid_log_level", value)
            settingsSavedMessage = nil
            return
        }

        await self.patchSingleConfig(setting.configKey, value: .string(normalized))
    }

    func applyProxyPorts(autoSaved: Bool = false) async {
        cancelProxyPortRetry()
        await waitForProxyPortRetryToStop()
        guard let body = self.validatedPortPatchBody(
            fields: self.proxyPortFields,
            errorMessageKey: "app.settings.error.port_range",
            skipEmptyValues: false)
        else { return }

        let syncingKey = autoSaved ? "ports-auto" : "ports"
        let successMessage = autoSaved ? tr("app.settings.saved.ports_auto") : tr("app.settings.saved.ports")
        let values = proxyPortFields.compactMap { Int($0.value.trimmed) }
        if !isRemoteTarget, !isRuntimeRunning, values.count == 5 {
            let ports = ProxyPortValues(port: values[0], socksPort: values[1], mixedPort: values[2], redirPort: values[3], tproxyPort: values[4])
            manualProxyPorts = ports
            encodeToDefaults(ports, key: "clashbar.settings.proxyPorts.manual.v1")
            settingsErrorMessage = nil
            settingsSavedMessage = successMessage
            scheduleSettingsFeedbackAutoClearIfNeeded(message: successMessage)
            return
        }
        let applied = await self.patchConfigBody(body, syncingKey: syncingKey, successMessage: successMessage)
        if applied, !isRemoteTarget, values.count == 5 {
            let ports = ProxyPortValues(port: values[0], socksPort: values[1], mixedPort: values[2], redirPort: values[3], tproxyPort: values[4])
            manualProxyPorts = ports
            encodeToDefaults(ports, key: "clashbar.settings.proxyPorts.manual.v1")
        }
    }

    func scheduleProxyPortsAutoSaveIfNeeded() {
        guard !suppressSettingsPersistence else { return }
        cancelProxyPortRetry()
        guard settingsSyncingKey == nil else { return }

        proxyPortsAutoSaveTask?.cancel()
        proxyPortsAutoSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 750_000_000)
            } catch {
                return
            }

            guard let self else { return }
            if Task.isCancelled {
                return
            }
            self.proxyPortsAutoSaveTask = nil
            await self.applyProxyPorts(autoSaved: true)
        }
    }

    func cancelProxyPortsAutoSave() {
        proxyPortsAutoSaveTask?.cancel()
        proxyPortsAutoSaveTask = nil
    }

    func syncEditableSettings(from config: ConfigSnapshot) {
        let incoming = EditableSettingsSnapshot(config: config)

        if preserveLocalSettingsOnNextSync {
            preserveLocalSettingsOnNextSync = false
            lastSyncedEditableSettings = incoming
            persistEditableSettingsSnapshot()
            return
        }

        guard let previous = lastSyncedEditableSettings else {
            self.applyEditableSettingsSnapshotToUI(incoming)
            lastSyncedEditableSettings = incoming
            persistEditableSettingsSnapshot()
            return
        }

        suppressSettingsPersistence = true
        self.syncEditableFields(
            from: previous,
            to: incoming,
            fields: [
                (\.settingsAllowLan, \.allowLan),
                (\.settingsIPv6, \.ipv6),
                (\.settingsTCPConcurrent, \.tcpConcurrent),
                (\.isTunEnabled, \.tunEnabled),
            ])

        self.syncEditableFields(
            from: previous,
            to: incoming,
            fields: [
                (\.settingsLogLevel, \.logLevel),
                (\.settingsPort, \.port),
                (\.settingsSocksPort, \.socksPort),
                (\.settingsMixedPort, \.mixedPort),
                (\.settingsRedirPort, \.redirPort),
                (\.settingsTProxyPort, \.tproxyPort),
            ])
        suppressSettingsPersistence = false

        lastSyncedEditableSettings = incoming
        persistEditableSettingsSnapshot()
    }

    func currentEditableSettingsSnapshot() -> EditableSettingsSnapshot {
        EditableSettingsSnapshot(
            mode: currentMode,
            allowLan: settingsAllowLan,
            ipv6: settingsIPv6,
            tcpConcurrent: settingsTCPConcurrent,
            tunEnabled: isTunEnabled,
            logLevel: settingsLogLevel,
            port: settingsPort,
            socksPort: settingsSocksPort,
            mixedPort: settingsMixedPort,
            redirPort: settingsRedirPort,
            tproxyPort: settingsTProxyPort)
    }

    func applyPendingConfigSwitchSettingsOverlayIfNeeded() async {
        guard let overlay = pendingConfigSwitchOverlaySettings else { return }
        pendingConfigSwitchOverlaySettings = nil
        _ = await self.applyEditableSettingsOverlay(
            overlay,
            syncingKey: "config-switch-overlay",
            successMessage: tr("app.settings.overlay_success"))
    }

    func applyPendingAppLaunchSettingsOverlayIfNeeded(syncSystemProxyPort: Bool = true) async {
        guard let overlay = pendingAppLaunchOverlaySettings else { return }
        guard apiStatus == .healthy else { return }
        pendingAppLaunchOverlaySettings = nil
        _ = await self.applyEditableSettingsOverlay(
            overlay,
            syncingKey: "app-launch-overlay",
            successMessage: "",
            syncSystemProxyPort: syncSystemProxyPort)
    }

    func syncEditableSettingsOverlayForCoreBootstrap(
        _ overlay: EditableSettingsSnapshot,
        syncingKey: String) async
    {
        self.deferredEditableSettingsOverlay = (snapshot: overlay, syncingKey: syncingKey)

        if await self.applyDeferredEditableSettingsOverlayIfPossible() {
            self.deferredEditableSettingsOverlayTask?.cancel()
            self.deferredEditableSettingsOverlayTask = nil
            return
        }

        self.scheduleDeferredEditableSettingsOverlaySync()
    }

    func cancelDeferredEditableSettingsOverlaySync() {
        self.deferredEditableSettingsOverlayTask?.cancel()
        self.deferredEditableSettingsOverlayTask = nil
        self.deferredEditableSettingsOverlay = nil
    }

    @discardableResult
    func applyEditableSettingsOverlay(
        _ overlay: EditableSettingsSnapshot,
        syncingKey: String,
        successMessage: String,
        syncSystemProxyPort: Bool = true) async -> Bool
    {
        let fallback = lastSyncedEditableSettings
        let resolvedLogLevel = overlay.logLevel.trimmed.isEmpty
            ? (fallback?.logLevel ?? ConfigLogLevel.info.rawValue)
            : overlay.logLevel

        guard ConfigLogLevel(rawValue: resolvedLogLevel) != nil else {
            settingsErrorMessage = tr("app.settings.error.overlay_invalid_log_level", resolvedLogLevel)
            settingsSavedMessage = nil
            return false
        }

        let resolvedPortFields = [
            SettingsPortField(key: "port", value: overlay.port.trimmedNonEmpty ?? fallback?.port.trimmed ?? ""),
            SettingsPortField(
                key: "socks-port",
                value: overlay.socksPort.trimmedNonEmpty ?? fallback?.socksPort.trimmed ?? ""),
            SettingsPortField(
                key: "mixed-port",
                value: overlay.mixedPort.trimmedNonEmpty ?? fallback?.mixedPort.trimmed ?? ""),
            SettingsPortField(
                key: "redir-port",
                value: overlay.redirPort.trimmedNonEmpty ?? fallback?.redirPort.trimmed ?? ""),
            SettingsPortField(
                key: "tproxy-port",
                value: overlay.tproxyPort.trimmedNonEmpty ?? fallback?.tproxyPort.trimmed ?? ""),
        ]
        let portBody: [String: ConfigPatchValue]
        if isRemoteTarget {
            guard let body = validatedPortPatchBody(
                fields: resolvedPortFields,
                errorMessageKey: "app.settings.error.overlay_port_range",
                skipEmptyValues: true) else { return false }
            portBody = body
        } else {
            do {
                portBody = try resolvedProxyPorts().patch
            } catch {
                settingsErrorMessage = error.localizedDescription
                appendLog(level: "error", message: error.localizedDescription)
                return false
            }
        }

        var body: [String: ConfigPatchValue] = [
            "mode": .string(overlay.mode.rawValue),
            "allow-lan": .bool(overlay.allowLan),
            "ipv6": .bool(overlay.ipv6),
            "tcp-concurrent": .bool(overlay.tcpConcurrent),
            "log-level": .string(resolvedLogLevel),
        ]
        let tunBody = await self.tunOverlayPatchBody(enabled: overlay.tunEnabled)
        body["tun"] = .object(tunBody)
        for (key, value) in portBody {
            body[key] = value
        }

        return await self.patchConfigBody(
            body,
            syncingKey: syncingKey,
            successMessage: successMessage,
            syncSystemProxyPort: syncSystemProxyPort)
    }
}
