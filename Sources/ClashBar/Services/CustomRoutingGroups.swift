import Foundation

struct CustomRoutingGroup: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var routeNames: [String]
    var ruleSelectors: [String]

    init(id: UUID = UUID(), name: String, routeNames: [String], ruleSelectors: [String] = []) {
        self.id = id
        self.name = name
        self.routeNames = routeNames
        self.ruleSelectors = ruleSelectors
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, routeNames, proxyNames, ruleSelectors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        routeNames = try container.decodeIfPresent([String].self, forKey: .routeNames)
            ?? container.decodeIfPresent([String].self, forKey: .proxyNames) ?? []
        ruleSelectors = try container.decodeIfPresent([String].self, forKey: .ruleSelectors) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(routeNames, forKey: .routeNames)
        try container.encode(ruleSelectors, forKey: .ruleSelectors)
    }
}

enum CustomRoutingGroupStoreError: LocalizedError {
    case configurationAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .configurationAlreadyExists(let name): "Routing groups already exist for configuration: \(name)"
        }
    }
}

struct CustomRoutingGroupStore: Sendable {
    private struct State: Codable {
        var groupsByConfiguration: [String: [CustomRoutingGroup]] = [:]
    }

    let stateDirectoryURL: URL

    private var fileURL: URL {
        stateDirectoryURL.appendingPathComponent("routing-groups.json", isDirectory: false)
    }

    func groups(for configurationName: String) throws -> [CustomRoutingGroup] {
        try readState().groupsByConfiguration[configurationName] ?? []
    }

    func save(_ groups: [CustomRoutingGroup], for configurationName: String) throws {
        var state = try readState()
        if groups.isEmpty {
            state.groupsByConfiguration.removeValue(forKey: configurationName)
        } else {
            state.groupsByConfiguration[configurationName] = groups
        }
        try FileManager.default.createDirectory(at: stateDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }

    func renameConfiguration(from oldName: String, to newName: String) throws {
        guard oldName != newName else { return }
        var state = try readState()
        if state.groupsByConfiguration[oldName] != nil, state.groupsByConfiguration[newName] != nil {
            throw CustomRoutingGroupStoreError.configurationAlreadyExists(newName)
        }
        guard let groups = state.groupsByConfiguration.removeValue(forKey: oldName) else { return }
        state.groupsByConfiguration[newName] = groups
        try FileManager.default.createDirectory(at: stateDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }

    private func readState() throws -> State {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return State() }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: fileURL))
    }
}

enum RuleRoute {
    static func target(in rule: String) -> String? {
        guard let firstComma = rule.firstIndex(of: ",") else { return nil }
        let ruleType = String(rule[..<firstComma]).uppercased()
        if ["AND", "OR", "NOT"].contains(ruleType), let lastComma = rule.lastIndex(of: ","), lastComma != firstComma {
            return nonEmpty(rule[rule.index(after: lastComma)...])
        }
        guard let secondComma = rule[rule.index(after: firstComma)...].firstIndex(of: ",") else {
            return ["MATCH", "FINAL"].contains(ruleType) ? nonEmpty(rule[rule.index(after: firstComma)...]) : nil
        }
        let targetStart = rule.index(after: secondComma)
        let targetEnd = rule[targetStart...].firstIndex(of: ",") ?? rule.endIndex
        return nonEmpty(rule[targetStart..<targetEnd])
    }

    static func replacingTarget(in rule: String, with target: String) -> String? {
        guard let firstComma = rule.firstIndex(of: ",") else { return nil }
        let ruleType = String(rule[..<firstComma]).uppercased()
        let targetStart: String.Index
        let targetEnd: String.Index
        if ["AND", "OR", "NOT"].contains(ruleType), let lastComma = rule.lastIndex(of: ","), lastComma != firstComma {
            targetStart = rule.index(after: lastComma)
            targetEnd = rule.endIndex
        } else if let secondComma = rule[rule.index(after: firstComma)...].firstIndex(of: ",") {
            targetStart = rule.index(after: secondComma)
            targetEnd = rule[targetStart...].firstIndex(of: ",") ?? rule.endIndex
        } else if ["MATCH", "FINAL"].contains(ruleType) {
            targetStart = rule.index(after: firstComma)
            targetEnd = rule.endIndex
        } else {
            return nil
        }
        guard nonEmpty(rule[targetStart..<targetEnd]) != nil else { return nil }
        return String(rule[..<targetStart]) + target + String(rule[targetEnd...])
    }

    static func selector(for rule: String) -> String {
        replacingTarget(in: rule, with: "__CLASHBAR_ROUTING_GROUP__") ?? rule
    }

    private static func nonEmpty(_ value: Substring) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
