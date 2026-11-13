import Foundation
import Yams

struct WorkingDirectoryManager {
    let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    var rootDirectoryURL: URL {
        self.homeDirectory.appendingPathComponent("config/clashbar", isDirectory: true)
    }

    var legacyRootDirectoryURL: URL {
        self.homeDirectory.appendingPathComponent("Library/Application Support/clashbar", isDirectory: true)
    }

    var configDirectoryURL: URL {
        self.rootDirectoryURL.appendingPathComponent("config", isDirectory: true)
    }

    var logsDirectoryURL: URL {
        self.rootDirectoryURL.appendingPathComponent("logs", isDirectory: true)
    }

    var stateDirectoryURL: URL {
        self.rootDirectoryURL.appendingPathComponent("state", isDirectory: true)
    }

    var remoteSubscriptionsURL: URL {
        self.stateDirectoryURL.appendingPathComponent("subscriptions.json", isDirectory: false)
    }

    var iconDirectoryURL: URL {
        self.rootDirectoryURL.appendingPathComponent("icon", isDirectory: true)
    }

    var coreDirectoryURL: URL {
        self.rootDirectoryURL.appendingPathComponent("core", isDirectory: true)
    }

    var managedMihomoBinaryURL: URL {
        self.coreDirectoryURL.appendingPathComponent("mihomo", isDirectory: false)
    }

    func bootstrapDirectories(fileManager: FileManager = .default) throws {
        try self.migrateLegacyDirectoryIfNeeded(fileManager: fileManager)
        try self.createDirectoryIfNeeded(self.rootDirectoryURL, fileManager: fileManager)
        try self.createDirectoryIfNeeded(self.configDirectoryURL, fileManager: fileManager)
        try self.createDirectoryIfNeeded(self.logsDirectoryURL, fileManager: fileManager)
        try self.createDirectoryIfNeeded(self.stateDirectoryURL, fileManager: fileManager)
        try self.createDirectoryIfNeeded(self.iconDirectoryURL, fileManager: fileManager)
        try self.createDirectoryIfNeeded(self.coreDirectoryURL, fileManager: fileManager)
    }

    private func migrateLegacyDirectoryIfNeeded(fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: self.legacyRootDirectoryURL.path) else { return }
        try fileManager.createDirectory(
            at: self.rootDirectoryURL,
            withIntermediateDirectories: true)
        try self.mergeDirectory(
            from: self.legacyRootDirectoryURL,
            to: self.rootDirectoryURL,
            fileManager: fileManager)
    }

    private func mergeDirectory(from source: URL, to destination: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for sourceItem in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [])
        {
            let destinationItem = destination.appendingPathComponent(sourceItem.lastPathComponent)
            let values = try sourceItem.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try self.mergeDirectory(from: sourceItem, to: destinationItem, fileManager: fileManager)
            } else if !fileManager.fileExists(atPath: destinationItem.path) {
                try fileManager.copyItem(at: sourceItem, to: destinationItem)
            }
        }
    }

    func normalizeAndValidateWithinRoot(_ url: URL, mustBeDirectory: Bool? = nil) throws -> URL {
        let standardized = url.standardizedFileURL
        let root = self.rootDirectoryURL.standardizedFileURL
        guard self.isDescendantOrEqual(standardized, parent: root) else {
            throw NSError(
                domain: "ClashBar.PathSecurity",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Path escapes ClashBar working directory: \(standardized.path)"])
        }

        if let mustBeDirectory {
            let resolved = standardized.resolvingSymlinksInPath()
            let values = try resolved.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory != mustBeDirectory {
                throw NSError(
                    domain: "ClashBar.PathSecurity",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: mustBeDirectory
                        ? "Expected directory path: \(standardized.path)"
                        : "Expected file path: \(standardized.path)"])
            }
        }

        return standardized
    }

    private func createDirectoryIfNeeded(_ url: URL, fileManager: FileManager) throws {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw NSError(
                    domain: "ClashBar.PathSecurity",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "Expected directory but found file: \(url.path)"])
            }
            return
        }

        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func isDescendantOrEqual(_ child: URL, parent: URL) -> Bool {
        let childComponents = child.pathComponents
        let parentComponents = parent.pathComponents

        guard parentComponents.count <= childComponents.count else { return false }
        return zip(parentComponents, childComponents).allSatisfy { $0 == $1 }
    }
}

@MainActor
final class ConfigDirectoryManager {
    private let workingDirectoryManager: WorkingDirectoryManager

    private(set) var configDirectory: URL?
    private(set) var availableConfigs: [URL] = []
    private(set) var selectedConfig: URL?
    private var selectionCleared = false

    init(workingDirectoryManager: WorkingDirectoryManager = WorkingDirectoryManager()) {
        self.workingDirectoryManager = workingDirectoryManager
    }

    func chooseConfigDirectory() -> URL? {
        do {
            try self.workingDirectoryManager.bootstrapDirectories()
            let target = try workingDirectoryManager.normalizeAndValidateWithinRoot(
                self.workingDirectoryManager.configDirectoryURL,
                mustBeDirectory: true)
            self.configDirectory = target
            self.reloadConfigs()
            return target
        } catch {
            return nil
        }
    }

    func setConfigDirectory(_ url: URL) {
        guard let safeURL = try? workingDirectoryManager.normalizeAndValidateWithinRoot(url, mustBeDirectory: true),
              safeURL == workingDirectoryManager.configDirectoryURL.standardizedFileURL
        else {
            return
        }
        self.configDirectory = safeURL
        self.reloadConfigs()
    }

    func selectConfig(_ url: URL) {
        guard let configDirectory else { return }
        let safeConfig = try? self.workingDirectoryManager.normalizeAndValidateWithinRoot(url, mustBeDirectory: false)
        guard let safeConfig,
              safeConfig.deletingLastPathComponent() == configDirectory,
              ["yaml", "yml"].contains(safeConfig.pathExtension.lowercased())
        else {
            return
        }
        self.selectedConfig = safeConfig
        self.selectionCleared = false
    }

    func clearSelection() {
        self.selectedConfig = nil
        self.selectionCleared = true
    }

    @discardableResult
    func reloadConfigs() -> [URL] {
        guard let configDirectory else {
            self.applyScannedConfigs([])
            return []
        }

        let files = Self.scanConfigFiles(in: configDirectory)
        self.applyScannedConfigs(files)
        return files
    }

    func applyScannedConfigs(_ files: [URL]) {
        self.availableConfigs = files
        if let selectedConfig, files.contains(selectedConfig) {
            return
        }
        self.selectedConfig = selectionCleared ? nil : files.first
    }

    nonisolated static func scanConfigFiles(in directory: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])) ?? []

        return children.filter { fileURL in
            let resolved = fileURL.resolvingSymlinksInPath()
            let isRegularFile = (try? resolved.resourceValues(forKeys: keys).isRegularFile) ?? false
            let fileExtension = fileURL.pathExtension.lowercased()
            return isRegularFile && (fileExtension == "yaml" || fileExtension == "yml")
        }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }
}

struct ConfigImportService {
    struct Download {
        let data: Data
        let usage: SubscriptionUsage?
        let suggestedName: String?
    }
    private let maxRemoteConfigBytes = 5 * 1024 * 1024

    @discardableResult
    func writeConfigData(_ data: Data, to targetURL: URL) throws -> Bool {
        guard !data.isEmpty else {
            throw NSError(
                domain: "ClashBar.ConfigImport",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: "Remote config response is empty"])
        }

        guard self.validateClashConfigData(data) else {
            throw NSError(
                domain: "ClashBar.ConfigImport",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: "Configuration is not a valid YAML mapping"])
        }

        if let existing = try? Data(contentsOf: targetURL), existing == data {
            return false
        }

        try data.write(to: targetURL, options: .atomic)
        return true
    }

    private func validateClashConfigData(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else {
            return false
        }

        guard let document = try? Yams.compose(yaml: text) else { return false }
        return document.mapping != nil
    }

    func normalizedConfigFileName(_ fileName: String, fallback: String? = nil) -> String? {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? (fallback ?? "") : trimmed
        let candidate = URL(fileURLWithPath: baseName).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate != ".", candidate != ".." else { return nil }

        let ext = (candidate as NSString).pathExtension.lowercased()
        if ext.isEmpty {
            return "\(candidate).yaml"
        }
        guard ext == "yaml" || ext == "yml" else { return nil }
        return candidate
    }

    func inferredRemoteConfigFileName(from remoteURL: URL) -> String {
        guard let host = remoteURL.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return "remote-config.yaml"
        }
        let safeHost = host.replacingOccurrences(of: ":", with: "-")
        return "\(safeHost).yaml"
    }

    /// Reads the optional human-readable title emitted by subscription
    /// providers. Clash itself does not require a name field, so callers must
    /// always retain a URL-based fallback.
    func inferredRemoteConfigDisplayName(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let document = try? Yams.compose(yaml: text),
              document.mapping != nil else {
            return nil
        }

        let topLevelKeys = ["name", "display-name", "display_name", "profile-name", "profile_name", "title", "remarks"]
        for key in topLevelKeys {
            if let name = self.normalizedRemoteConfigDisplayName(document[key]?.string) {
                return name
            }
        }

        // A few providers wrap metadata under profile or metadata. Do not
        // inspect proxy names/groups: those are not subscription titles.
        for containerKey in ["profile", "metadata", "meta"] {
            guard let container = document[containerKey] else { continue }
            for key in ["name", "display-name", "display_name", "title", "remarks"] {
                if let name = self.normalizedRemoteConfigDisplayName(container[key]?.string) {
                    return name
                }
            }
        }
        return nil
    }

    private func normalizedRemoteConfigDisplayName(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        guard !value.contains("/"), !value.contains("\\"), !value.contains(":") else { return nil }
        value = value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != "..", value.count <= 120 else { return nil }
        if value.lowercased().hasSuffix(".yaml") {
            value = String(value.dropLast(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if value.lowercased().hasSuffix(".yml") {
            value = String(value.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty else { return nil }
        return value
    }

    func isSupportedRemoteConfigURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    func downloadRemoteConfigData(from remoteURL: URL, userAgent: String? = nil) async throws -> Data {
        try await downloadRemoteConfig(from: remoteURL, userAgent: userAgent).data
    }

    func downloadRemoteConfig(from remoteURL: URL, userAgent: String? = nil) async throws -> Download {
        let session = URLSessionFactory.makeEphemeralSession(options: .init(
            timeoutIntervalForRequest: 15,
            timeoutIntervalForResource: 30))
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: remoteURL)
        if let userAgent {
            let trimmed = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                request.setValue(trimmed, forHTTPHeaderField: "User-Agent")
            }
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            throw APIError.statusCode(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }

        if http.expectedContentLength > Int64(self.maxRemoteConfigBytes) {
            throw self.remoteConfigTooLargeError(limit: self.maxRemoteConfigBytes)
        }

        var data = Data()
        data.reserveCapacity(min(self.maxRemoteConfigBytes, 64 * 1024))
        for try await byte in bytes {
            if data.count >= self.maxRemoteConfigBytes {
                throw self.remoteConfigTooLargeError(limit: self.maxRemoteConfigBytes)
            }
            data.append(byte)
        }
        let suggestedName = Self.normalizedSuggestedName(
            http.value(forHTTPHeaderField: "profile-title")
                ?? http.value(forHTTPHeaderField: "profile-name")
                ?? Self.contentDispositionFileName(http.value(forHTTPHeaderField: "content-disposition")))
        return Download(
            data: data,
            usage: SubscriptionUsage.parse(http.value(forHTTPHeaderField: "subscription-userinfo")),
            suggestedName: suggestedName)
    }

    private static func normalizedSuggestedName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("/"), !value.contains("\\"), !value.contains(":") else { return nil }
        let withoutExtension: String
        if value.lowercased().hasSuffix(".yaml") {
            withoutExtension = String(value.dropLast(5))
        } else if value.lowercased().hasSuffix(".yml") {
            withoutExtension = String(value.dropLast(4))
        } else {
            withoutExtension = value
        }
        guard !withoutExtension.isEmpty else { return nil }
        return withoutExtension.count <= 120
            ? withoutExtension
            : String(withoutExtension.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func contentDispositionFileName(_ header: String?) -> String? {
        guard let header else { return nil }
        for key in ["filename*=", "filename="] {
            guard let range = header.range(of: key, options: [.caseInsensitive]) else { continue }
            var value = String(header[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let separator = value.firstIndex(of: ";") {
                value = String(value[..<separator])
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if key == "filename*=" {
                value = String(value.split(separator: "'", maxSplits: 2).last ?? Substring(value))
                    .removingPercentEncoding ?? value
            } else {
                value = value.removingPercentEncoding ?? value
            }
            if let normalized = Self.normalizedSuggestedName(value) {
                return normalized
            }
        }
        return nil
    }

    private func remoteConfigTooLargeError(limit: Int) -> NSError {
        NSError(
            domain: "ClashBar.ConfigImport",
            code: 413,
            userInfo: [NSLocalizedDescriptionKey: "Remote config exceeds size limit (\(limit) bytes)"])
    }
}

@MainActor
final class ConfigService {
    let configManager: ConfigDirectoryManager
    let configImportService: ConfigImportService

    init(
        configManager: ConfigDirectoryManager,
        configImportService: ConfigImportService)
    {
        self.configManager = configManager
        self.configImportService = configImportService
    }

    var configDirectory: URL? {
        self.configManager.configDirectory
    }

    var availableConfigs: [URL] {
        self.configManager.availableConfigs
    }

    var selectedConfig: URL? {
        self.configManager.selectedConfig
    }

    func chooseConfigDirectory() -> URL? {
        self.configManager.chooseConfigDirectory()
    }

    func setConfigDirectory(_ url: URL) {
        self.configManager.setConfigDirectory(url)
    }

    func selectConfig(_ url: URL) {
        self.configManager.selectConfig(url)
    }

    func clearSelection() {
        self.configManager.clearSelection()
    }

    @discardableResult
    func reloadConfigs() -> [URL] {
        self.configManager.reloadConfigs()
    }

    func applyScannedConfigs(_ files: [URL]) {
        self.configManager.applyScannedConfigs(files)
    }

    @discardableResult
    func writeConfigData(_ data: Data, to targetURL: URL) throws -> Bool {
        try self.configImportService.writeConfigData(data, to: targetURL)
    }

    func normalizedConfigFileName(_ fileName: String, fallback: String? = nil) -> String? {
        self.configImportService.normalizedConfigFileName(fileName, fallback: fallback)
    }

    func inferredRemoteConfigFileName(from remoteURL: URL) -> String {
        self.configImportService.inferredRemoteConfigFileName(from: remoteURL)
    }

    func inferredRemoteConfigDisplayName(from data: Data) -> String? {
        self.configImportService.inferredRemoteConfigDisplayName(from: data)
    }

    func isSupportedRemoteConfigURL(_ url: URL) -> Bool {
        self.configImportService.isSupportedRemoteConfigURL(url)
    }

    func downloadRemoteConfigData(from remoteURL: URL, userAgent: String? = nil) async throws -> Data {
        try await self.configImportService.downloadRemoteConfigData(from: remoteURL, userAgent: userAgent)
    }

    func downloadRemoteConfig(from remoteURL: URL, userAgent: String? = nil) async throws -> ConfigImportService.Download {
        try await self.configImportService.downloadRemoteConfig(from: remoteURL, userAgent: userAgent)
    }
}
