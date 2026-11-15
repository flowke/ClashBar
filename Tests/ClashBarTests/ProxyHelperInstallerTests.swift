import Foundation
import ProxyHelperShared
import XCTest
@testable import ClashBar

final class ProxyHelperInstallerTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClashBarHelperLookup-\(UUID().uuidString)", isDirectory: true)

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: self.root.path) {
            try FileManager.default.removeItem(at: self.root)
        }
        try super.tearDownWithError()
    }

    func testXcodeRunFindsHelperBesideExecutableInBothConfigurations() throws {
        for configuration in ["Debug", "Release"] {
            let products = self.root.appendingPathComponent("DerivedData/Build/Products/\(configuration)")
            let executable = products.appendingPathComponent("ClashBar")
            let helper = products.appendingPathComponent("ClashBarProxyHelper")
            try self.createExecutable(at: helper)

            XCTAssertEqual(
                ProxyHelperInstaller.helperBinaryURL(bundleURL: products, executableURL: executable), helper)
        }
    }

    func testMissingHelperDoesNotUseAnotherConfiguration() throws {
        let products = self.root.appendingPathComponent("Build/Products")
        try self.createExecutable(at: products.appendingPathComponent("Debug/ClashBarProxyHelper"))

        XCTAssertNil(ProxyHelperInstaller.helperBinaryURL(
            bundleURL: products.appendingPathComponent("Release"),
            executableURL: products.appendingPathComponent("Release/ClashBar")))
    }

    func testPackagedAppUsesEmbeddedHelper() throws {
        let app = self.root.appendingPathComponent("Applications/ClashBar.app")
        let helper = app.appendingPathComponent(ProxyHelperConstants.helperBundleProgram)
        try self.createExecutable(at: helper)
        try self.createFile(at: app.appendingPathComponent(ProxyHelperConstants.helperBundlePlist))
        try self.createExecutable(at: app.deletingLastPathComponent().appendingPathComponent("ClashBarProxyHelper"))

        XCTAssertEqual(ProxyHelperInstaller.helperBinaryURL(
            bundleURL: app, executableURL: app.appendingPathComponent("Contents/MacOS/ClashBar")), helper)
    }

    func testIncompleteAppDoesNotUseExternalHelper() throws {
        let app = self.root.appendingPathComponent("Applications/ClashBar.app")
        try self.createExecutable(at: app.appendingPathComponent(ProxyHelperConstants.helperBundleProgram))
        try self.createExecutable(at: app.deletingLastPathComponent().appendingPathComponent("ClashBarProxyHelper"))

        XCTAssertNil(ProxyHelperInstaller.helperBinaryURL(
            bundleURL: app, executableURL: app.appendingPathComponent("Contents/MacOS/ClashBar")))
    }

    func testNonExecutableHelperIsRejected() throws {
        let products = self.root.appendingPathComponent("Build/Products/Debug")
        try self.createFile(at: products.appendingPathComponent("ClashBarProxyHelper"))

        XCTAssertNil(ProxyHelperInstaller.helperBinaryURL(
            bundleURL: products, executableURL: products.appendingPathComponent("ClashBar")))
    }

    func testSharedPackageSchemeBuildsHelperAlongsideApp() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let scheme = try XMLDocument(contentsOf: project.appendingPathComponent(
            ".swiftpm/xcode/xcshareddata/xcschemes/ClashBar.xcscheme"))
        let entries = try scheme.nodes(forXPath: "/Scheme/BuildAction/BuildActionEntries/BuildActionEntry")
        for target in ["ClashBar", "ClashBarProxyHelper"] {
            let entry = try XCTUnwrap(entries.compactMap { $0 as? XMLElement }.first {
                $0.elements(forName: "BuildableReference").first?
                    .attribute(forName: "BlueprintIdentifier")?.stringValue == target
            })
            for action in ["buildForRunning", "buildForProfiling", "buildForArchiving", "buildForTesting"] {
                XCTAssertEqual(entry.attribute(forName: action)?.stringValue, "YES", "\(target): \(action)")
            }
        }
    }

    private func createExecutable(at url: URL) throws {
        try self.createFile(at: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func createFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
}
