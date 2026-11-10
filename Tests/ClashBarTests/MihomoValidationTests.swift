import Foundation
import Darwin
import XCTest
@testable import ClashBar

final class MihomoValidationTests: XCTestCase {
    func testMihomoRestoresSelectedGroupsAfterRestart() async throws {
        guard let binary = ProcessInfo.processInfo.environment["CLASHBAR_TEST_MIHOMO"] else {
            throw XCTSkip("Set CLASHBAR_TEST_MIHOMO to run the isolated Mihomo test")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { close(fd); throw POSIXError(.EIO) }
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &addressLength) }
        }
        close(fd)
        guard named == 0 else { throw POSIXError(.EIO) }
        let controller = "127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        let config = root.appendingPathComponent("config.yaml")
        let source = """
        mixed-port: 0
        mode: rule
        proxy-groups:
          - {name: Main, type: select, proxies: [Nested, DIRECT, REJECT]}
          - {name: Nested, type: select, proxies: [DIRECT, REJECT]}
          - {name: Other, type: select, proxies: [DIRECT, REJECT]}
        rules: ['MATCH,DIRECT']
        """
        try ConfigRuleMerger().merge(Data(source.utf8), changes: []).write(to: config)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let logURL = root.appendingPathComponent("mihomo.log")
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        func launch() throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["-d", root.path, "-f", config.path, "-ext-ctl", controller]
            process.standardOutput = log
            process.standardError = log
            try process.run()
            return process
        }
        func request(_ group: String, target: String? = nil) async throws -> String? {
            var request = URLRequest(url: URL(string: "http://\(controller)/proxies/\(group)")!)
            if let target {
                request.httpMethod = "PUT"
                request.httpBody = try JSONEncoder().encode(["name": target])
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw POSIXError(.EIO)
            }
            guard target == nil else { return nil }
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["now"] as? String
        }
        func waitUntilReady() async throws {
            for _ in 0..<100 {
                if (try? await request("Main")) != nil { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let details = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            throw NSError(domain: "MihomoTest", code: 1, userInfo: [NSLocalizedDescriptionKey: details])
        }
        let first = try launch()
        defer { if first.isRunning { first.terminate(); first.waitUntilExit() } }
        try await waitUntilReady()
        _ = try await request("Main", target: "DIRECT")
        _ = try await request("Main", target: "Nested")
        _ = try await request("Nested", target: "REJECT")
        _ = try await request("Other", target: "REJECT")
        first.terminate()
        first.waitUntilExit()
        let second = try launch()
        defer { if second.isRunning { second.terminate(); second.waitUntilExit() } }
        try await waitUntilReady()
        let main = try await request("Main")
        let nested = try await request("Nested")
        let other = try await request("Other")
        XCTAssertEqual(main, "Nested")
        XCTAssertEqual(nested, "REJECT")
        XCTAssertEqual(other, "REJECT")
        second.terminate()
        second.waitUntilExit()
        let updatedSource = source.replacingOccurrences(of: "name: Nested, type: select, proxies: [DIRECT, REJECT]", with: "name: Nested, type: select, proxies: [DIRECT]")
        try ConfigRuleMerger().merge(Data(updatedSource.utf8), changes: []).write(to: config)
        let third = try launch()
        defer { if third.isRunning { third.terminate(); third.waitUntilExit() } }
        try await waitUntilReady()
        let remainingMain = try await request("Main")
        let missingNested = try await request("Nested")
        let remainingOther = try await request("Other")
        XCTAssertEqual(remainingMain, "Nested")
        XCTAssertEqual(missingNested, "DIRECT")
        XCTAssertEqual(remainingOther, "REJECT")
    }

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
