import Foundation
import XCTest
@testable import ClashBar

final class MihomoValidationTests: XCTestCase {
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
