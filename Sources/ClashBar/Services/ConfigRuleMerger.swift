import Foundation
import Yams

struct ProxyPortValues: Codable, Equatable {
    var port: Int
    var socksPort: Int
    var mixedPort: Int
    var redirPort: Int
    var tproxyPort: Int

    init(port: Int, socksPort: Int, mixedPort: Int, redirPort: Int, tproxyPort: Int) {
        self.port = port
        self.socksPort = socksPort
        self.mixedPort = mixedPort
        self.redirPort = redirPort
        self.tproxyPort = tproxyPort
    }

    init(config: ConfigSnapshot) {
        self.init(port: config.port ?? 0, socksPort: config.socksPort ?? 0,
                  mixedPort: config.mixedPort ?? 0, redirPort: config.redirPort ?? 0,
                  tproxyPort: config.tproxyPort ?? 0)
    }

    static func firstMismatch(in requested: [String: ConfigPatchValue], actual: ProxyPortValues)
        -> (key: String, expected: Int, actual: Int)?
    {
        let values = [("port", actual.port), ("socks-port", actual.socksPort),
                      ("mixed-port", actual.mixedPort), ("redir-port", actual.redirPort),
                      ("tproxy-port", actual.tproxyPort)]
        for (key, value) in values {
            if case let .int(expected)? = requested[key], expected != value {
                return (key, expected, value)
            }
        }
        return nil
    }

    static func mismatchedPatch(in requested: [String: ConfigPatchValue], actual: ProxyPortValues)
        -> [String: ConfigPatchValue]
    {
        let actualValues = actual.patch
        return requested.filter { key, value in
            guard case let .int(expected) = value, case let .int(current)? = actualValues[key] else { return false }
            return expected != current
        }
    }

    var patch: [String: ConfigPatchValue] {
        ["port": .int(port), "socks-port": .int(socksPort), "mixed-port": .int(mixedPort),
         "redir-port": .int(redirPort), "tproxy-port": .int(tproxyPort)]
    }

    static func fromConfig(_ data: Data) throws -> ProxyPortValues {
        guard let text = String(data: data, encoding: .utf8),
              let document = try Yams.compose(yaml: text), document.mapping != nil else {
            throw ConfigRuleMergeError.invalidDocument
        }
        func value(_ key: String) throws -> Int {
            guard let node = document[key] else { return 0 }
            guard let scalar = node.scalar, let number = Int(scalar.string), (0...65535).contains(number) else {
                throw ProxyPortError.invalidValue(key)
            }
            return number
        }
        let hasProxyPort = ["port", "socks-port", "mixed-port"].contains { document[$0] != nil }
        return try ProxyPortValues(
            port: value("port"), socksPort: value("socks-port"),
            mixedPort: hasProxyPort ? value("mixed-port") : 7890,
            redirPort: value("redir-port"), tproxyPort: value("tproxy-port"))
    }
}

enum ProxyPortError: LocalizedError {
    case invalidValue(String)
    case missingConfig

    var errorDescription: String? {
        switch self {
        case .invalidValue(let key): "Invalid proxy port in configuration: \(key)"
        case .missingConfig: "No selected configuration is available."
        }
    }
}

struct ProxyPortRuntimeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

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
    case invalidDocument, invalidRules, invalidProfile, emptyRule, missingOriginal(String)

    var errorDescription: String? {
        switch self {
        case .invalidDocument: "Configuration must be a YAML mapping."
        case .invalidRules: "The rules field must be a list of strings."
        case .invalidProfile: "The profile field must be a mapping."
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
        try enableSelectionPersistence(in: &document)
        return Data(try Yams.serialize(node: document).utf8)
    }

    func enablingSelectionPersistence(_ data: Data) throws -> Data? {
        guard let text = String(data: data, encoding: .utf8),
              var document = try Yams.compose(yaml: text), document.mapping != nil else {
            throw ConfigRuleMergeError.invalidDocument
        }
        if document["profile"]?["store-selected"]?.scalar?.string == "true" { return nil }
        try enableSelectionPersistence(in: &document)
        return Data(try Yams.serialize(node: document).utf8)
    }

    private func enableSelectionPersistence(in document: inout Node) throws {
        var profile = document["profile"] ?? Node([(Node, Node)]())
        guard profile.mapping != nil else { throw ConfigRuleMergeError.invalidProfile }
        profile["store-selected"] = Node("true", Tag(.bool))
        document["profile"] = profile
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
