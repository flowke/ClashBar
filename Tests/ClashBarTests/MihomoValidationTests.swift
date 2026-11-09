import Foundation
import XCTest
@testable import ClashBar

final class MihomoValidationTests: XCTestCase {
    @MainActor
    func testSlowValidationDoesNotBlockMainActor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = WorkingDirectoryManager(homeDirectory: root)
        try directory.bootstrapDirectories()
        let binary = directory.managedMihomoBinaryURL
        try Data("#!/bin/sh\n/bin/sleep 1\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let config = directory.configDirectoryURL.appendingPathComponent("test.yaml")
        try Data("mode: rule\n".utf8).write(to: config)
        let core: any MihomoControlling = MihomoProcessManager(workingDirectoryManager: directory)
        var finished = false
        let validation = Task { @MainActor in
            try await core.validateConfigAsync(configPath: config.path)
            finished = true
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(finished, "The main actor must remain responsive while validation is running")
        try await validation.value
        XCTAssertTrue(finished)
    }

    func testGeneratedConfigurationPassesMihomoValidation() throws {
        guard let binary = ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"] else {
            throw XCTSkip("Set CLASHBAR_TEST_MIHOMO to run the isolated Mihomo validation")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = Data("mode: rule\nproxies: []\nrules:\n  - MATCH,DIRECT\n".utf8)
        let result = try ConfigRuleMerger().merge(input, changes: [
            CustomRuleChange(operation: .add, original: "", value: "DOMAIN,example.com,DIRECT"),
        ])
        let config = root.appendingPathComponent("config.yaml")
        try result.write(to: config)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-d", root.path, "-f", config.path, "-t"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
    }
}
