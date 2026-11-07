import Foundation
import Yams

struct CustomRuleChange: Codable, Equatable, Identifiable {
    enum Operation: String, Codable, CaseIterable {
        case add, replace, delete
    }

    var id: UUID = UUID()
    var operation: Operation
    var original: String
    var value: String
}

enum ConfigRuleMergeError: LocalizedError {
    case invalidDocument, invalidRules, emptyRule, missingOriginal(String)

    var errorDescription: String? {
        switch self {
        case .invalidDocument: "Configuration must be a YAML mapping."
        case .invalidRules: "The rules field must be a list of strings."
        case .emptyRule: "A rule cannot be empty."
        case .missingOriginal(let rule): "The original rule was not found: \(rule)"
        }
    }
}

struct ConfigRuleMerger {
    struct ResolvedRule {
        var value: String
        var origin: CustomRuleChange.Operation?
    }

    func rules(in data: Data) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8),
              let document = try Yams.compose(yaml: text), document.mapping != nil else {
            throw ConfigRuleMergeError.invalidDocument
        }
        guard let node = document["rules"] else { return [] }
        guard let sequence = node.sequence else { throw ConfigRuleMergeError.invalidRules }
        return try sequence.map {
            guard let value = $0.string else { throw ConfigRuleMergeError.invalidRules }
            return value
        }
    }

    func merge(_ data: Data, changes: [CustomRuleChange]) throws -> Data {
        guard let text = String(data: data, encoding: .utf8),
              var document = try Yams.compose(yaml: text), document.mapping != nil else {
            throw ConfigRuleMergeError.invalidDocument
        }
        let result = try resolve(rules: rules(in: data), changes: changes)
        if !changes.isEmpty || document["rules"] != nil {
            document["rules"] = Node(result.map { Node($0.value, .implicit, .doubleQuoted) })
        }
        return Data(try Yams.serialize(node: document).utf8)
    }

    func resolve(rules originalRules: [String], changes: [CustomRuleChange]) throws -> [ResolvedRule] {
        var rules = originalRules.map { ResolvedRule(value: $0, origin: nil) }
        var additions: [ResolvedRule] = []
        for change in changes {
            let original = change.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = change.value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch change.operation {
            case .add:
                guard !value.isEmpty else { throw ConfigRuleMergeError.emptyRule }
                additions.append(ResolvedRule(value: value, origin: .add))
            case .replace, .delete:
                guard !original.isEmpty else { throw ConfigRuleMergeError.emptyRule }
                guard let index = rules.firstIndex(where: { $0.value == original }) else {
                    throw ConfigRuleMergeError.missingOriginal(original)
                }
                if change.operation == .replace {
                    guard !value.isEmpty else { throw ConfigRuleMergeError.emptyRule }
                    rules[index] = ResolvedRule(value: value, origin: .replace)
                } else {
                    rules.remove(at: index)
                }
            }
        }
        return additions + rules
    }
}
