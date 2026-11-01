import Foundation

enum WebUIKind: String, CaseIterable, Codable, Hashable, Identifiable {
    case metaCubeXD = "metacubexd"

    var id: String { self.rawValue }

    var titleKey: String {
        "ui.action.webui.metacubexd"
    }

    var symbolName: String {
        "globe.americas.fill"
    }

    var assetDirectoryName: String { self.rawValue }

    var releaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/MetaCubeX/metacubexd/releases/latest")!
    }

    var preferredArchiveNames: [String] {
        ["compressed-dist.tgz", "dist.zip", "metacubexd.zip"]
    }

    var bundledVersion: String { "1.273.1" }

    var bundledArchiveResourcePath: String { "compressed-dist.tgz" }
}

enum WebUIAssetState: String, Codable, Equatable {
    case unavailable
    case available
    case checking
    case updateAvailable
    case updating
    case failed
}

struct WebUIAssetStatus: Codable, Equatable {
    let kind: WebUIKind
    var currentVersion: String?
    var latestVersion: String?
    var lastCheckedAt: Date?
    var state: WebUIAssetState
    var errorMessage: String?

    static func unavailable(for kind: WebUIKind) -> WebUIAssetStatus {
        WebUIAssetStatus(
            kind: kind,
            currentVersion: nil,
            latestVersion: nil,
            lastCheckedAt: nil,
            state: .unavailable,
            errorMessage: nil)
    }
}

private struct WebUIRelease: Decodable {
    let tagName: String
    let isDraft: Bool
    let isPrerelease: Bool
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let downloadURL: URL

        private enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case assets
    }
}

private struct WebUIMetadata: Codable {
    var currentVersion: String?
    var latestVersion: String?
    var lastCheckedAt: Date?
}

@MainActor
final class WebUIAssetService {
    let workingDirectoryManager: WorkingDirectoryManager
    private let session: URLSession
    private let fileManager: FileManager
    private(set) var statuses: [WebUIKind: WebUIAssetStatus] = [:]

    init(
        workingDirectoryManager: WorkingDirectoryManager,
        session: URLSession,
        fileManager: FileManager = .default)
    {
        self.workingDirectoryManager = workingDirectoryManager
        self.session = session
        self.fileManager = fileManager
        self.statuses = Dictionary(uniqueKeysWithValues: WebUIKind.allCases.map {
            ($0, .unavailable(for: $0))
        })
    }

    var rootDirectoryURL: URL {
        self.workingDirectoryManager.rootDirectoryURL.appendingPathComponent("webui", isDirectory: true)
    }

    func assetDirectoryURL(for kind: WebUIKind) -> URL {
        self.rootDirectoryURL.appendingPathComponent(kind.assetDirectoryName, isDirectory: true)
    }

    func currentDirectoryURL(for kind: WebUIKind) -> URL {
        self.assetDirectoryURL(for: kind)
    }

    func bootstrap() {
        do {
            try self.fileManager.createDirectory(at: self.rootDirectoryURL, withIntermediateDirectories: true)
            for kind in WebUIKind.allCases {
                try self.fileManager.createDirectory(
                    at: self.assetDirectoryURL(for: kind),
                    withIntermediateDirectories: true)
                let bundledResource = URL(fileURLWithPath: kind.bundledArchiveResourcePath)
                if !self.hasUsableIndex(for: kind),
                   let bundledURL = Bundle.module.url(
                       forResource: bundledResource.deletingPathExtension().lastPathComponent,
                       withExtension: bundledResource.pathExtension),
                   let bundledData = try? Data(contentsOf: bundledURL)
                {
                    try self.installArchive(
                        bundledData,
                        for: kind,
                        version: kind.bundledVersion,
                        archiveName: bundledURL.lastPathComponent)
                }
                self.reloadStatus(for: kind)
            }
        } catch {
            for kind in WebUIKind.allCases {
                self.statuses[kind] = WebUIAssetStatus(
                    kind: kind,
                    currentVersion: nil,
                    latestVersion: nil,
                    lastCheckedAt: nil,
                    state: .failed,
                    errorMessage: error.localizedDescription)
            }
        }
    }

    func isAvailable(_ kind: WebUIKind) -> Bool {
        self.statuses[kind]?.state == .available || self.statuses[kind]?.state == .updateAvailable
    }

    /// The parent directory is passed to mihomo's `external-ui` setting.
    func prepareMihomoDirectory() throws -> URL {
        try self.fileManager.createDirectory(at: self.rootDirectoryURL, withIntermediateDirectories: true)
        return self.rootDirectoryURL
    }

    func reloadStatus(for kind: WebUIKind) {
        let metadata = self.readMetadata(for: kind)
        var available = self.hasUsableIndex(for: kind)
        if !available {
            available = self.restorePreviousVersionIfUsable(for: kind)
        }
        var status = self.statuses[kind] ?? .unavailable(for: kind)
        status.currentVersion = metadata.currentVersion
        status.latestVersion = metadata.latestVersion
        status.lastCheckedAt = metadata.lastCheckedAt
        status.errorMessage = nil
        status.state = available
            ? ((metadata.latestVersion != nil && metadata.currentVersion != metadata.latestVersion)
                ? .updateAvailable : .available)
            : .unavailable
        self.statuses[kind] = status
    }

    private func restorePreviousVersionIfUsable(for kind: WebUIKind) -> Bool {
        let previousURL = self.rootDirectoryURL
            .appendingPathComponent(".\(kind.assetDirectoryName)-previous", isDirectory: true)
        guard self.hasUsableIndex(in: previousURL) else { return false }
        let currentURL = self.currentDirectoryURL(for: kind)
        try? self.fileManager.removeItem(at: currentURL)
        do {
            try self.fileManager.moveItem(at: previousURL, to: currentURL)
            return true
        } catch {
            return false
        }
    }

    func checkForUpdates(_ kind: WebUIKind) async {
        var status = self.statuses[kind] ?? .unavailable(for: kind)
        status.state = .checking
        status.errorMessage = nil
        self.statuses[kind] = status

        do {
            var request = URLRequest(url: kind.releaseAPIURL)
            request.timeoutInterval = 12
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("ClashBar", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw WebUIAssetError.invalidResponse
            }
            guard 200..<300 ~= httpResponse.statusCode else {
                throw WebUIAssetError.statusCode(httpResponse.statusCode)
            }
            let release = try JSONDecoder().decode(WebUIRelease.self, from: data)
            guard !release.isDraft, !release.isPrerelease else {
                throw WebUIAssetError.noStableRelease
            }

            status.latestVersion = AppSemanticVersion.normalizedDisplayVersion(from: release.tagName)
            status.lastCheckedAt = Date()
            status.state = self.hasUsableIndex(for: kind)
                ? (status.currentVersion == status.latestVersion ? .available : .updateAvailable)
                : .unavailable
            self.statuses[kind] = status
            self.writeMetadata(
                WebUIMetadata(
                    currentVersion: status.currentVersion,
                    latestVersion: status.latestVersion,
                    lastCheckedAt: status.lastCheckedAt),
                for: kind)
        } catch is CancellationError {
            self.reloadStatus(for: kind)
        } catch {
            status.state = self.hasUsableIndex(for: kind) ? .available : .failed
            status.errorMessage = error.localizedDescription
            self.statuses[kind] = status
        }
    }

    func update(_ kind: WebUIKind) async {
        var status = self.statuses[kind] ?? .unavailable(for: kind)
        status.state = .updating
        status.errorMessage = nil
        self.statuses[kind] = status

        do {
            let release = try await self.fetchLatestRelease(for: kind)
            guard let asset = self.selectArchive(from: release.assets, for: kind) else {
                throw WebUIAssetError.archiveNotFound
            }
            let (archiveData, response) = try await self.session.data(from: asset.downloadURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  200..<300 ~= httpResponse.statusCode
            else {
                throw WebUIAssetError.invalidArchiveResponse
            }
            guard archiveData.count <= 200 * 1024 * 1024 else {
                throw WebUIAssetError.archiveTooLarge
            }
            try self.installArchive(
                archiveData,
                for: kind,
                version: AppSemanticVersion.normalizedDisplayVersion(from: release.tagName),
                archiveName: asset.name)
            self.reloadStatus(for: kind)
        } catch is CancellationError {
            self.reloadStatus(for: kind)
        } catch {
            status.state = self.hasUsableIndex(for: kind) ? .available : .failed
            status.errorMessage = error.localizedDescription
            self.statuses[kind] = status
        }
    }

    private func fetchLatestRelease(for kind: WebUIKind) async throws -> WebUIRelease {
        var request = URLRequest(url: kind.releaseAPIURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ClashBar", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebUIAssetError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw WebUIAssetError.statusCode(httpResponse.statusCode)
        }
        let release = try JSONDecoder().decode(WebUIRelease.self, from: data)
        guard !release.isDraft, !release.isPrerelease else {
            throw WebUIAssetError.noStableRelease
        }
        return release
    }

    private func selectArchive(from assets: [WebUIRelease.Asset], for kind: WebUIKind) -> WebUIRelease.Asset? {
        for name in kind.preferredArchiveNames {
            if let match = assets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return match
            }
        }
        return assets.first(where: {
            let name = $0.name.lowercased()
            return name.hasSuffix(".zip") || name.hasSuffix(".tgz") || name.hasSuffix(".tar.gz")
        })
    }

    private func installArchive(
        _ data: Data,
        for kind: WebUIKind,
        version: String,
        archiveName: String) throws
    {
        let temporaryRoot = self.fileManager.temporaryDirectory
            .appendingPathComponent("clashbar-webui-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let safeArchiveName = URL(fileURLWithPath: archiveName).lastPathComponent
        let archiveURL = temporaryRoot.appendingPathComponent(safeArchiveName)
        let extractedURL = temporaryRoot.appendingPathComponent("extracted", isDirectory: true)
        let stagingURL = self.rootDirectoryURL
            .appendingPathComponent(".\(kind.assetDirectoryName)-staging-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        defer {
            try? self.fileManager.removeItem(at: temporaryRoot)
            try? self.fileManager.removeItem(at: stagingURL)
        }

        try self.fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try self.fileManager.createDirectory(at: extractedURL, withIntermediateDirectories: true)
        try data.write(to: archiveURL, options: .atomic)
        try self.extractArchive(archiveURL, to: extractedURL)

        guard let indexURL = self.findIndexFile(in: extractedURL) else {
            throw WebUIAssetError.indexNotFound
        }
        let contentRoot = indexURL.deletingLastPathComponent()
        try self.fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        for item in try self.fileManager.contentsOfDirectory(at: contentRoot, includingPropertiesForKeys: nil) {
            try self.fileManager.copyItem(at: item, to: stagingURL.appendingPathComponent(item.lastPathComponent))
        }

        let currentURL = self.currentDirectoryURL(for: kind)
        let previousURL = self.rootDirectoryURL
            .appendingPathComponent(".\(kind.assetDirectoryName)-previous", isDirectory: true)
        try? self.fileManager.removeItem(at: previousURL)
        if self.fileManager.fileExists(atPath: currentURL.path) {
            try self.fileManager.moveItem(at: currentURL, to: previousURL)
        }
        do {
            try self.fileManager.moveItem(at: stagingURL, to: currentURL)
        } catch {
            try? self.fileManager.removeItem(at: currentURL)
            if self.fileManager.fileExists(atPath: previousURL.path) {
                try? self.fileManager.moveItem(at: previousURL, to: currentURL)
            }
            throw error
        }

        let metadata = WebUIMetadata(
            currentVersion: version,
            latestVersion: version,
            lastCheckedAt: Date())
        self.writeMetadata(metadata, for: kind)
    }

    private func extractArchive(_ archiveURL: URL, to destinationURL: URL) throws {
        let process = Process()
        if archiveURL.path.lowercased().hasSuffix(".zip") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archiveURL.path, "-C", destinationURL.path]
        }
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                .trimmedNonEmpty ?? "unknown extraction error"
            throw WebUIAssetError.extractionFailed(details)
        }
    }

    private func findIndexFile(in root: URL) -> URL? {
        guard let enumerator = self.fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        else { return nil }

        for case let itemURL as URL in enumerator {
            guard itemURL.lastPathComponent.caseInsensitiveCompare("index.html") == .orderedSame else { continue }
            let values = try? itemURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            if let size = try? itemURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                return itemURL
            }
        }
        return nil
    }

    private func hasUsableIndex(for kind: WebUIKind) -> Bool {
        self.hasUsableIndex(in: self.currentDirectoryURL(for: kind))
    }

    private func hasUsableIndex(in directoryURL: URL) -> Bool {
        guard let indexURL = self.fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey])?.compactMap({ $0 as? URL }).first(where: {
                $0.lastPathComponent.caseInsensitiveCompare("index.html") == .orderedSame
            })
        else { return false }
        guard let values = try? indexURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else { return false }
        return size > 0
    }

    private func metadataURL(for kind: WebUIKind) -> URL {
        self.rootDirectoryURL
            .appendingPathComponent(".\(kind.assetDirectoryName)-metadata.json", isDirectory: false)
    }

    private func readMetadata(for kind: WebUIKind) -> WebUIMetadata {
        guard let data = try? Data(contentsOf: self.metadataURL(for: kind)),
              let metadata = try? JSONDecoder().decode(WebUIMetadata.self, from: data)
        else { return WebUIMetadata(currentVersion: nil, latestVersion: nil, lastCheckedAt: nil) }
        return metadata
    }

    private func writeMetadata(_ metadata: WebUIMetadata, for kind: WebUIKind) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: self.metadataURL(for: kind), options: .atomic)
    }
}

private enum WebUIAssetError: LocalizedError {
    case invalidResponse
    case statusCode(Int)
    case noStableRelease
    case archiveNotFound
    case invalidArchiveResponse
    case archiveTooLarge
    case indexNotFound
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid WebUI release response."
        case let .statusCode(code): "WebUI release request failed (HTTP \(code))."
        case .noStableRelease: "No stable WebUI release is available."
        case .archiveNotFound: "The WebUI release did not contain a ZIP archive."
        case .invalidArchiveResponse: "The WebUI archive download failed."
        case .archiveTooLarge: "The WebUI archive is too large."
        case .indexNotFound: "The WebUI archive did not contain index.html."
        case let .extractionFailed(message): "Unable to extract WebUI archive: \(message)"
        }
    }
}
