import AppKit
import Foundation

@MainActor
extension AppViewModel {
    func refreshWebUIStatuses() {
        self.webUIStatuses = self.webUIAssetService.statuses
    }

    func isWebUIAvailable(_ kind: WebUIKind) -> Bool {
        guard !self.isRemoteTarget else { return true }
        return self.webUIStatuses[kind].map { status in
            status.state == .available || status.state == .updateAvailable
        } ?? false
    }

    func checkForWebUIUpdates(_ kind: WebUIKind) async {
        self.refreshWebUIStatuses()
        guard var status = self.webUIStatuses[kind],
              status.state != .checking, status.state != .updating
        else { return }
        status.state = .checking
        status.errorMessage = nil
        self.webUIStatuses[kind] = status
        await self.webUIAssetService.checkForUpdates(kind)
        self.refreshWebUIStatuses()
    }

    func updateWebUI(_ kind: WebUIKind) async {
        self.refreshWebUIStatuses()
        guard var status = self.webUIStatuses[kind],
              status.state != .checking, status.state != .updating
        else { return }
        status.state = .updating
        status.errorMessage = nil
        self.webUIStatuses[kind] = status
        await self.webUIAssetService.update(kind)
        self.refreshWebUIStatuses()
    }

    func openWebUI(_ kind: WebUIKind) {
        let targetURL: String
        if self.isRemoteTarget {
            targetURL = self.controllerUIURL
        } else {
            targetURL = self.managedWebUIURL(for: kind)
        }
        guard let url = URL(string: targetURL) else { return }
        _ = NSWorkspace.shared.open(url)
    }

    func managedWebUIURL(for kind: WebUIKind) -> String {
        let base = self.normalizedControllerAddress(self.controller)
        guard var components = URLComponents(string: base) else { return base }
        components.path = "/ui/\(kind.assetDirectoryName)/"
        components.query = nil
        components.fragment = self.webUISetupFragment()
        return components.string ?? base
    }

    /// Keep the controller setup hand-off consistent with the existing
    /// MetaCubeXD fallback URL while using the same Mihomo endpoint.
    private func webUISetupFragment() -> String {
        let controllerComponents = URLComponents(string: self.normalizedControllerAddress(self.controller))
        let usesHTTPS = controllerComponents?.scheme?.lowercased() == "https"
        let host = controllerComponents?.host?.trimmedNonEmpty ?? "127.0.0.1"
        let port = controllerComponents?.port ?? (usesHTTPS ? 443 : 80)
        var fragmentComponents = URLComponents()
        fragmentComponents.path = "/setup"
        fragmentComponents.queryItems = [
            URLQueryItem(name: "http", value: usesHTTPS ? "false" : "true"),
            URLQueryItem(name: "hostname", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "secret", value: self.controllerSecret?.trimmed ?? ""),
        ]
        return fragmentComponents.string ?? "/setup"
    }

    /// Mihomo reads `external-ui` at process startup. We own this directory
    /// for local targets so MetaCubeXD is served from `/ui/metacubexd/`.
    func prepareManagedWebUIConfiguration(at configPath: String) {
        guard !self.isRemoteTarget else { return }
        do {
            let root = try self.webUIAssetService.prepareMihomoDirectory()
            let url = URL(fileURLWithPath: configPath)
            guard var content = try? String(contentsOf: url, encoding: .utf8) else { return }
            let value = self.yamlQuotedScalar(root.path)
            let lines = content.components(separatedBy: .newlines)
            var replaced = false
            var output: [String] = []
            for line in lines {
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                let body = line.dropFirst(indent.count)
                if indent.isEmpty, !body.hasPrefix("#"),
                   body.range(of: "^external-ui\\s*:", options: .regularExpression) != nil {
                    output.append("\(indent)external-ui: \(value)")
                    replaced = true
                } else if indent.isEmpty, !body.hasPrefix("#"),
                          body.range(of: "^external-ui-(url|name)\\s*:", options: .regularExpression) != nil {
                    // These options can make mihomo download/serve a remote
                    // dashboard, which would override ClashBar's managed tree.
                    continue
                } else {
                    output.append(line)
                }
            }
            if !replaced {
                if !content.hasSuffix("\n") { content.append("\n") }
                output = content.components(separatedBy: .newlines)
                if output.last == "" { output.removeLast() }
                output.append("external-ui: \(value)")
            }
            let updated = output.joined(separator: "\n")
            guard updated != content else { return }
            try updated.write(to: url, atomically: true, encoding: .utf8)
            self.syncConfigSignatureSnapshotToMonitorBaseline()
        } catch {
            self.appendLog(
                level: "error",
                message: "Unable to configure managed WebUI directory: \(error.localizedDescription)")
        }
    }

    private func yamlQuotedScalar(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
