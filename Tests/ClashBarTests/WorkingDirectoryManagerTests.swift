import Foundation
import XCTest
@testable import ClashBar

final class WorkingDirectoryManagerTests: XCTestCase {
    func testUsesDotConfigAsPrimaryRoot() {
        let home = URL(fileURLWithPath: "/tmp/clashbar-home", isDirectory: true)
        let directory = WorkingDirectoryManager(homeDirectory: home)

        XCTAssertEqual(directory.rootDirectoryURL.path, "/tmp/clashbar-home/.config/clashbar")
        XCTAssertEqual(directory.configDirectoryURL.path, "/tmp/clashbar-home/.config/clashbar/config")
        XCTAssertEqual(directory.legacyRootDirectoryURLs.map(\.path), [
            "/tmp/clashbar-home/config/clashbar",
            "/tmp/clashbar-home/Library/Application Support/clashbar",
        ])
    }

    func testMigratesBothLegacyRootsWithoutOverwritingNewFiles() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("clashbar-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let directory = WorkingDirectoryManager(homeDirectory: home)
        let previousRoot = directory.previousRootDirectoryURL
        let historicalRoot = directory.legacyRootDirectoryURL
        let currentRoot = directory.rootDirectoryURL

        try FileManager.default.createDirectory(
            at: previousRoot.appendingPathComponent("config"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: previousRoot.appendingPathComponent("logs"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: historicalRoot.appendingPathComponent("state"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: currentRoot.appendingPathComponent("config"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: currentRoot.appendingPathComponent("logs"),
            withIntermediateDirectories: true)

        try Data("new".utf8).write(to: currentRoot.appendingPathComponent("config/Keep.yaml"), options: .atomic)
        try Data("previous".utf8).write(to: previousRoot.appendingPathComponent("config/Keep.yaml"), options: .atomic)
        try Data("from previous".utf8).write(to: previousRoot.appendingPathComponent("config/Previous.yaml"), options: .atomic)
        try Data("from history".utf8).write(to: historicalRoot.appendingPathComponent("state/history.json"), options: .atomic)
        try Data("nested".utf8).write(
            to: previousRoot.appendingPathComponent("logs/nested.log"),
            options: .atomic)

        try directory.bootstrapDirectories()

        XCTAssertEqual(
            String(decoding: try Data(contentsOf: currentRoot.appendingPathComponent("config/Keep.yaml")), as: UTF8.self),
            "new")
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: currentRoot.appendingPathComponent("config/Previous.yaml")), as: UTF8.self),
            "from previous")
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: currentRoot.appendingPathComponent("state/history.json")), as: UTF8.self),
            "from history")
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentRoot.appendingPathComponent("logs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentRoot.appendingPathComponent("logs/nested.log").path))
    }

    func testMapsPersistedLegacyPathsToPrimaryRoot() {
        let home = URL(fileURLWithPath: "/tmp/clashbar-home", isDirectory: true)
        let directory = WorkingDirectoryManager(homeDirectory: home)
        let oldPath = directory.previousRootDirectoryURL
            .appendingPathComponent("config/Subscription.yaml")

        XCTAssertEqual(
            directory.currentURL(forPersistedURL: oldPath).path,
            directory.rootDirectoryURL.appendingPathComponent("config/Subscription.yaml").path)
        XCTAssertEqual(
            directory.currentURL(forPersistedURL: URL(fileURLWithPath: "/tmp/elsewhere.yaml")).path,
            "/tmp/elsewhere.yaml")
    }
}
