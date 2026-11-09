import Foundation

struct EffectiveConfigRecord: Codable, Equatable {
    var fileName: String
    var baseName: String
    var changes: [CustomRuleChange]
}

enum EffectiveConfigTransactionError: LocalizedError {
    case rollbackFailed(String, String)

    var errorDescription: String? {
        switch self {
        case let .rollbackFailed(original, rollback):
            "Configuration update failed: \(original). Restoring the previous runtime configuration also failed: \(rollback)"
        }
    }
}

@MainActor
struct EffectiveConfigTransaction {
    let configDirectory: URL
    let stateDirectory: URL

    private var recordURL: URL { stateDirectory.appendingPathComponent("effective-config.json") }

    func currentRecord() throws -> EffectiveConfigRecord? {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        return try JSONDecoder().decode(EffectiveConfigRecord.self, from: Data(contentsOf: recordURL))
    }

    func currentFile(_ record: EffectiveConfigRecord) -> URL? {
        guard record.fileName.hasPrefix(".clashbar-effective-"),
              record.fileName == URL(fileURLWithPath: record.fileName).lastPathComponent else { return nil }
        return configDirectory.appendingPathComponent(record.fileName)
    }

    func deleteSelectedSource(_ source: URL) throws -> EffectiveConfigRecord {
        let previousData = try FileManager.default.fileExists(atPath: recordURL.path) ? Data(contentsOf: recordURL) : nil
        let previous = try currentRecord()
        let detached = EffectiveConfigRecord(fileName: "", baseName: "", changes: previous?.changes ?? [])
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(detached).write(to: recordURL, options: .atomic)
        do {
            try FileManager.default.removeItem(at: source)
        } catch {
            do {
                if let previousData {
                    try previousData.write(to: recordURL, options: .atomic)
                } else {
                    try FileManager.default.removeItem(at: recordURL)
                }
            } catch let rollbackError {
                throw EffectiveConfigTransactionError.rollbackFailed(error.localizedDescription, rollbackError.localizedDescription)
            }
            throw error
        }
        if let previous, let oldURL = currentFile(previous) {
            try? FileManager.default.removeItem(at: oldURL)
        }
        return detached
    }

    @discardableResult
    func commit(
        data: Data,
        baseName: String,
        changes: [CustomRuleChange],
        validate: (URL) async throws -> Void,
        apply: (URL) async throws -> Void,
        finalize: () throws -> Void = {},
        rollback: () async throws -> Void
    ) async throws -> EffectiveConfigRecord {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let previous = try currentRecord()
        let fileName = ".clashbar-effective-\(UUID().uuidString).yaml"
        let candidate = configDirectory.appendingPathComponent(fileName)
        let record = EffectiveConfigRecord(fileName: fileName, baseName: baseName, changes: changes)
        let encodedRecord = try JSONEncoder().encode(record)
        var committed = false
        defer {
            if !committed { try? fileManager.removeItem(at: candidate) }
        }

        try data.write(to: candidate, options: .atomic)
        try await validate(candidate)
        do {
            try await apply(candidate)
            try finalize()
            try encodedRecord.write(to: recordURL, options: .atomic)
        } catch {
            do {
                try await rollback()
            } catch let rollbackError {
                // Keep the candidate available if the runtime could still be using it.
                committed = true
                throw EffectiveConfigTransactionError.rollbackFailed(error.localizedDescription, rollbackError.localizedDescription)
            }
            throw error
        }
        committed = true
        if let previous, let oldURL = currentFile(previous), oldURL != candidate {
            try? fileManager.removeItem(at: oldURL)
        }
        return record
    }
}
