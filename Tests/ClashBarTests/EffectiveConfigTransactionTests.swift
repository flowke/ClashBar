import Foundation
import XCTest
@testable import ClashBar

@MainActor
final class EffectiveConfigTransactionTests: XCTestCase {
    func testDeletingMissingSourceRestoresPreviousRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transaction = EffectiveConfigTransaction(configDirectory: root, stateDirectory: root)
        let original = try await transaction.commit(data: Data("first".utf8), baseName: "a.yaml", changes: [], validate: { _ in }, apply: { _ in }, rollback: {})
        XCTAssertThrowsError(try transaction.deleteSelectedSource(root.appendingPathComponent("missing.yaml")))
        XCTAssertEqual(try transaction.currentRecord(), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(transaction.currentFile(original)).path))
    }

    func testValidationFailurePreservesPreviousVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transaction = EffectiveConfigTransaction(configDirectory: root, stateDirectory: root)
        let first = try await transaction.commit(data: Data("first".utf8), baseName: "a.yaml", changes: [], validate: { _ in }, apply: { _ in }, rollback: {})
        var applied = false
        do {
            _ = try await transaction.commit(data: Data("broken".utf8), baseName: "b.yaml", changes: [], validate: { _ in
                throw CocoaError(.fileReadCorruptFile)
            }, apply: { _ in applied = true }, rollback: {})
            XCTFail("Expected validation to fail")
        } catch {}
        XCTAssertFalse(applied)
        XCTAssertEqual(try transaction.currentRecord(), first)
        let path = try XCTUnwrap(transaction.currentFile(first))
        XCTAssertEqual(try Data(contentsOf: path), Data("first".utf8))
    }

    func testApplyFailureDoesNotChangeRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transaction = EffectiveConfigTransaction(configDirectory: root, stateDirectory: root)
        let first = try await transaction.commit(data: Data("first".utf8), baseName: "a.yaml", changes: [], validate: { _ in }, apply: { _ in }, rollback: {})
        var rolledBack = false
        do {
            _ = try await transaction.commit(data: Data("second".utf8), baseName: "b.yaml", changes: [], validate: { _ in }, apply: { _ in
                throw CocoaError(.fileWriteUnknown)
            }, rollback: { rolledBack = true })
            XCTFail("Expected apply to fail")
        } catch {}
        XCTAssertTrue(rolledBack)
        XCTAssertEqual(try transaction.currentRecord(), first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(transaction.currentFile(first)).path))
    }

    func testFinalizeFailureRestoresSourceAndRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transaction = EffectiveConfigTransaction(configDirectory: root, stateDirectory: root)
        let first = try await transaction.commit(data: Data("first".utf8), baseName: "a.yaml", changes: [], validate: { _ in }, apply: { _ in }, rollback: {})
        var runtime = "first"
        var source = "old"
        do {
            _ = try await transaction.commit(data: Data("second".utf8), baseName: "a.yaml", changes: [], validate: { _ in }, apply: { _ in
                runtime = "second"
            }, finalize: {
                source = "new"
                throw CocoaError(.fileWriteUnknown)
            }, rollback: {
                source = "old"
                runtime = "first"
            })
            XCTFail("Expected finalize to fail")
        } catch {}
        XCTAssertEqual(runtime, "first")
        XCTAssertEqual(source, "old")
        XCTAssertEqual(try transaction.currentRecord(), first)
    }
}
