import CryptoKit
import Foundation
import XCTest
@testable import ClashBar

private final class CoreDownloadProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [URL: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let data = Self.responses[url],
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class CoreInstallationTests: XCTestCase {
    func testInstallationThroughReleaseAndDownloadRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let architecture = try XCTUnwrap(CoreInstallationService.architecture)
        let cpu: UInt8 = architecture == "arm64" ? 0x0c : 0x07
        let header = Data([0xcf, 0xfa, 0xed, 0xfe, cpu, 0, 0, 1, 0, 0, 0, 0, 2, 0, 0, 0])
        let input = root.appendingPathComponent("input")
        let archive = root.appendingPathComponent("fixture.gz")
        try header.write(to: input)
        XCTAssertTrue(FileManager.default.createFile(atPath: archive.path, contents: nil))
        let output = try FileHandle(forWritingTo: archive)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-c", input.path]
        gzip.standardOutput = output
        try gzip.run()
        gzip.waitUntilExit()
        try output.close()
        XCTAssertEqual(gzip.terminationStatus, 0)
        let payload = try Data(contentsOf: archive)
        let digest = "sha256:" + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let tag = "v1.19.33"
        let prefix = architecture == "arm64" ? "mihomo-darwin-arm64-go122" : "mihomo-darwin-amd64-v2-go122"
        let name = "\(prefix)-\(tag).gz"
        let assetURL = try XCTUnwrap(URL(string: "https://github.com/MetaCubeX/mihomo/releases/download/\(tag)/\(name)"))
        let releaseURL = try XCTUnwrap(URL(string: "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"))
        let release = try JSONSerialization.data(withJSONObject: [
            "tag_name": tag,
            "assets": [["name": name, "browser_download_url": assetURL.absoluteString, "digest": digest]],
        ])
        CoreDownloadProtocol.responses = [releaseURL: release, assetURL: payload]
        defer { CoreDownloadProtocol.responses = [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoreDownloadProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let destination = root.appendingPathComponent("core", isDirectory: true)
        try await CoreInstallationService.install(in: destination, session: session)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("mihomo")), header)
    }

    func testOfficialDownloadIntoTemporaryDirectory() async throws {
        guard ProcessInfo.processInfo.environment["CLASHBAR_TEST_CORE_DOWNLOAD"] == "1" else {
            throw XCTSkip("Set CLASHBAR_TEST_CORE_DOWNLOAD=1 to download the official core")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await CoreInstallationService.install(in: root)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("mihomo").path))
    }

    func testSelectsOfficialAssetForArchitecture() throws {
        let tag = "v1.19.33"
        let name = "mihomo-darwin-arm64-go122-\(tag).gz"
        let asset = CoreInstallationService.Release.Asset(
            name: name,
            browserDownloadURL: try XCTUnwrap(URL(string: "https://github.com/MetaCubeX/mihomo/releases/download/\(tag)/\(name)")),
            digest: "sha256:" + String(repeating: "a", count: 64))
        let release = CoreInstallationService.Release(tagName: tag, assets: [asset])
        XCTAssertEqual(try CoreInstallationService.selectAsset(from: release, architecture: "arm64").name, name)
        XCTAssertThrowsError(try CoreInstallationService.selectAsset(from: release, architecture: "amd64"))
        let untrusted = CoreInstallationService.Release.Asset(
            name: name, browserDownloadURL: try XCTUnwrap(URL(string: "https://example.com/\(name)")), digest: asset.digest)
        XCTAssertThrowsError(try CoreInstallationService.selectAsset(
            from: .init(tagName: tag, assets: [untrusted]), architecture: "arm64"))
    }

    func testArchiveValidationAndExistingCoreProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input")
        let archive = root.appendingPathComponent("archive.gz")
        let destination = root.appendingPathComponent("installed")
        let header = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1, 0, 0, 0, 0, 2, 0, 0, 0])
        try header.write(to: input)
        XCTAssertTrue(FileManager.default.createFile(atPath: archive.path, contents: nil))
        let compressed = try FileHandle(forWritingTo: archive)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-c", input.path]
        gzip.standardOutput = compressed
        try gzip.run()
        gzip.waitUntilExit()
        try compressed.close()
        XCTAssertEqual(gzip.terminationStatus, 0)
        let digest = "sha256:" + SHA256.hash(data: try Data(contentsOf: archive))
            .map { String(format: "%02x", $0) }.joined()

        XCTAssertThrowsError(try CoreInstallationService.installArchive(
            archive, digest: "sha256:" + String(repeating: "0", count: 64),
            architecture: "arm64", destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertThrowsError(try CoreInstallationService.installArchive(
            archive, digest: digest, architecture: "amd64", destination: destination))
        try FileManager.default.removeItem(at: root.appendingPathComponent("mihomo"))
        try CoreInstallationService.installArchive(archive, digest: digest, architecture: "arm64", destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination), header)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.path))
        XCTAssertThrowsError(try CoreInstallationService.installArchive(
            archive, digest: digest, architecture: "arm64", destination: destination))
        XCTAssertEqual(try Data(contentsOf: destination), header)
    }
}
