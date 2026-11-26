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

struct CustomRuleChange: Codable, Equatable, Identifiable, Sendable {
    enum Operation: String, Codable, CaseIterable, Sendable {
        case add, replace, delete
    }

    var id: UUID = UUID()
    var operation: Operation
    var original: String
    var value: String
    var testURL: String? = nil
    var isEnabled = true
}

extension CustomRuleChange {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        operation = try container.decode(Operation.self, forKey: .operation)
        original = try container.decode(String.self, forKey: .original)
        value = try container.decode(String.self, forKey: .value)
        testURL = try container.decodeIfPresent(String.self, forKey: .testURL)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

enum ConfigRuleMergeError: LocalizedError {
    case invalidDocument, invalidRules, invalidProfile, invalidProxyGroups, emptyRule, missingOriginal(String)
    case invalidRoutingGroup(String), duplicateRoutingGroup(String), duplicateRuleAssignment(String)

    var errorDescription: String? {
        switch self {
        case .invalidDocument: "Configuration must be a YAML mapping."
        case .invalidRules: "The rules field must be a list of strings."
        case .invalidProfile: "The profile field must be a mapping."
        case .invalidProxyGroups: "The proxy-groups field must be a list."
        case .emptyRule: "A rule cannot be empty."
        case .missingOriginal(let rule): "The original rule was not found: \(rule)"
        case .invalidRoutingGroup(let name): "The routing group is invalid: \(name)"
        case .duplicateRoutingGroup(let name): "A proxy group with this name already exists: \(name)"
        case .duplicateRuleAssignment(let rule): "A rule is assigned to more than one custom routing group: \(rule)"
        }
    }
}

struct ConfigRuleMerger {
    struct ProxyGroupDefinition: Equatable, Sendable {
        var name: String
        var type: String
        var routes: [String]
        var providers: [String]
    }

    struct ResolvedRule {
        var value: String
        var origin: CustomRuleChange.Operation?
    }

    func rules(in data: Data) throws -> [String] {
        try rules(in: document(from: data))
    }

    func routingConfiguration(in data: Data, changes: [CustomRuleChange]) throws
        -> (proxyNames: Set<String>, proxyGroups: [ProxyGroupDefinition], rules: [String])
    {
        let document = try document(from: data)
        return try (proxyNames(in: document), proxyGroups(in: document),
                    resolve(rules: rules(in: document), changes: changes).map(\.value))
    }

    private func rules(in document: Node) throws -> [String] {
        guard let node = document["rules"] else { return [] }
        guard let sequence = node.sequence else { throw ConfigRuleMergeError.invalidRules }
        return try sequence.map {
            guard let value = $0.string else { throw ConfigRuleMergeError.invalidRules }
            return value
        }
    }

    func merge(_ data: Data, changes: [CustomRuleChange], routingGroups: [CustomRoutingGroup] = []) throws -> Data {
        var document = try document(from: data)
        var result = try resolve(rules: rules(in: document), changes: changes)
        let availableProxies = try proxyNames(in: document)
        let existingGroupNames = try proxyGroupNames(in: document)
        let reservedRoutes: Set<String> = ["DIRECT", "REJECT"]
        let availableRoutes = availableProxies.union(existingGroupNames).union(reservedRoutes)
        var assignedSelectors: [String: String] = [:]
        var newGroups: [Node] = []
        var knownGroupNames = Set(existingGroupNames).union(availableProxies).union(reservedRoutes)
        for group in routingGroups {
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let routeNames = Array(Set(group.routeNames.filter { !$0.isEmpty })).sorted()
            guard !name.isEmpty, !routeNames.isEmpty else { throw ConfigRuleMergeError.invalidRoutingGroup(name) }
            guard knownGroupNames.insert(name).inserted else { throw ConfigRuleMergeError.duplicateRoutingGroup(name) }
            for selector in group.ruleSelectors {
                guard assignedSelectors[selector] == nil else {
                    throw ConfigRuleMergeError.duplicateRuleAssignment(selector)
                }
                assignedSelectors[selector] = name
            }
            let existingMembers = routeNames.filter { availableRoutes.contains($0) }
            let members = existingMembers.isEmpty ? ["REJECT"] : existingMembers
            newGroups.append(Node([
                (Node("name"), Node(name, .implicit, .doubleQuoted)),
                (Node("type"), Node("select", .implicit, .doubleQuoted)),
                (Node("proxies"), Node(members.map { Node($0, .implicit, .doubleQuoted) })),
            ]))
        }
        result = result.map { rule in
            guard let groupName = assignedSelectors[RuleRoute.selector(for: rule.value)],
                  let rewritten = RuleRoute.replacingTarget(in: rule.value, with: groupName) else { return rule }
            return ResolvedRule(value: rewritten, origin: rule.origin)
        }
        if changes.contains(where: \.isEnabled) || document["rules"] != nil {
            document["rules"] = Node(result.map { Node($0.value, .implicit, .doubleQuoted) })
        }
        if !newGroups.isEmpty {
            var proxyGroups = document["proxy-groups"]?.sequence ?? []
            if document["proxy-groups"] != nil, document["proxy-groups"]?.sequence == nil {
                throw ConfigRuleMergeError.invalidProxyGroups
            }
            proxyGroups.append(contentsOf: newGroups)
            document["proxy-groups"] = .sequence(proxyGroups)
        }
        try enableSelectionPersistence(in: &document)
        return Data(try Yams.serialize(node: document).utf8)
    }

    func proxyNames(in data: Data) throws -> [String] {
        try proxyNames(in: document(from: data)).sorted()
    }

    func proxyGroupNames(in data: Data) throws -> [String] {
        try proxyGroupNames(in: document(from: data))
    }

    func proxyGroups(in data: Data) throws -> [ProxyGroupDefinition] {
        try proxyGroups(in: document(from: data))
    }

    private func proxyGroups(in document: Node) throws -> [ProxyGroupDefinition] {
        guard let node = document["proxy-groups"] else { return [] }
        guard let sequence = node.sequence else { throw ConfigRuleMergeError.invalidProxyGroups }
        return sequence.compactMap { group in
            guard let name = group["name"]?.string else { return nil }
            let routes = group["proxies"]?.sequence?.compactMap(\.string) ?? []
            let providers = group["use"]?.sequence?.compactMap(\.string) ?? []
            return ProxyGroupDefinition(name: name, type: group["type"]?.string ?? "unknown",
                                        routes: routes, providers: providers)
        }
    }

    func enablingSelectionPersistence(_ data: Data) throws -> Data? {
        var document = try document(from: data)
        if document["profile"]?["store-selected"]?.scalar?.string == "true" { return nil }
        try enableSelectionPersistence(in: &document)
        return Data(try Yams.serialize(node: document).utf8)
    }

    private func document(from data: Data) throws -> Node {
        guard let text = String(data: data, encoding: .utf8),
              let document = try Yams.compose(yaml: text), document.mapping != nil else {
            throw ConfigRuleMergeError.invalidDocument
        }
        return document
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
        for change in changes where change.isEnabled {
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

    private func proxyNames(in document: Node) throws -> Set<String> {
        guard let node = document["proxies"] else { return [] }
        guard let sequence = node.sequence else { throw ConfigRuleMergeError.invalidRules }
        return Set(sequence.compactMap { $0["name"]?.string })
    }

    private func proxyGroupNames(in document: Node) throws -> [String] {
        guard let node = document["proxy-groups"] else { return [] }
        guard let sequence = node.sequence else { throw ConfigRuleMergeError.invalidProxyGroups }
        return sequence.compactMap { $0["name"]?.string }
    }
}
