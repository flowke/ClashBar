import CryptoKit
import Foundation
import Yams

struct AgentRuleRequest: Decodable {
    let action: String
    let revision: String?
    let id: UUID?
    let operation: CustomRuleChange.Operation?
    let original: String?
    let value: String?
}

struct AgentRuleSnapshot: Encodable {
    let revision: String
    let baseName: String
    let coreRunning: Bool
    let changes: [CustomRuleChange]
    let baseRules: [String]
    let effectiveRules: [String]
    let policies: [String]
}

struct AgentRuleResponse: Encodable {
    let ok: Bool
    let code: String?
    let message: String?
    let snapshot: AgentRuleSnapshot?

    static func failure(_ code: String, _ message: String) -> Self {
        Self(ok: false, code: code, message: message, snapshot: nil)
    }
}

@MainActor
extension AppViewModel {
    func agentRuleSnapshot() throws -> AgentRuleSnapshot {
        guard !isRemoteTarget else { throw AgentRuleError.remoteTarget }
        guard let source = configService.selectedConfig else { throw AgentRuleError.noBase }
        let record = try effectiveConfigTransaction.currentRecord()
        guard record == nil || record?.baseName == source.lastPathComponent else { throw AgentRuleError.inconsistentBase }
        let data = try Data(contentsOf: source)
        let changes = record?.changes ?? []
        let rules = try ConfigRuleMerger().rules(in: data)
        let effective = try ConfigRuleMerger().resolve(rules: rules, changes: changes).map(\.value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var revisionData = Data(source.lastPathComponent.utf8)
        revisionData.append(0)
        revisionData.append(data)
        revisionData.append(try encoder.encode(changes))
        let revision = SHA256.hash(data: revisionData).map { String(format: "%02x", $0) }.joined()
        let document = try Yams.compose(yaml: String(decoding: data, as: UTF8.self))
        let groups = document?["proxy-groups"]?.sequence?.compactMap { $0["name"]?.string } ?? []
        let proxies = document?["proxies"]?.sequence?.compactMap { $0["name"]?.string } ?? []
        let policies = Array(Set(groups + proxies + proxyGroups.map(\.name) + ["DIRECT", "REJECT", "REJECT-DROP", "PASS"])).sorted()
        return AgentRuleSnapshot(revision: revision, baseName: source.lastPathComponent,
                                 coreRunning: processManager.isRunning, changes: changes,
                                 baseRules: rules, effectiveRules: effective, policies: policies)
    }

    func handleAgentRuleRequest(_ request: AgentRuleRequest) async -> AgentRuleResponse {
        do {
            guard !dashboardConfigBusy, !isCoreActionProcessing else { throw AgentRuleError.busy }
            let snapshot = try agentRuleSnapshot()
            if request.action == "list" {
                return AgentRuleResponse(ok: true, code: nil, message: nil, snapshot: snapshot)
            }
            guard request.revision == snapshot.revision else { throw AgentRuleError.conflict }
            var changes = snapshot.changes
            switch request.action {
            case "add", "update":
                guard let operation = request.operation else { throw AgentRuleError.invalidRequest }
                let original = request.original?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let value = request.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard (operation == .add || !original.isEmpty), (operation == .delete || !value.isEmpty),
                      !original.contains("\n"), !value.contains("\n"),
                      (operation != .add || original.isEmpty), (operation != .delete || value.isEmpty) else {
                    throw AgentRuleError.invalidRequest
                }
                if request.action == "add" {
                    changes.append(CustomRuleChange(operation: operation, original: original, value: value))
                } else {
                    guard let id = request.id, let index = changes.firstIndex(where: { $0.id == id }) else {
                        throw AgentRuleError.notFound
                    }
                    changes[index] = CustomRuleChange(id: id, operation: operation, original: original, value: value)
                }
            case "remove":
                guard let id = request.id, let index = changes.firstIndex(where: { $0.id == id }) else {
                    throw AgentRuleError.notFound
                }
                changes.remove(at: index)
            default:
                throw AgentRuleError.invalidRequest
            }
            let expectedRevision = snapshot.revision
            let ok = await applyDashboardConfiguration(baseName: snapshot.baseName, changes: changes, precondition: {
                guard try self.agentRuleSnapshot().revision == expectedRevision else { throw AgentRuleError.conflict }
            })
            guard ok else { return .failure("apply_failed", dashboardConfigError ?? "Configuration is busy or could not be applied.") }
            return AgentRuleResponse(ok: true, code: nil, message: nil, snapshot: try agentRuleSnapshot())
        } catch let error as AgentRuleError {
            return .failure(error.code, error.localizedDescription)
        } catch {
            return .failure("error", error.localizedDescription)
        }
    }
}

enum AgentRuleError: LocalizedError {
    case remoteTarget, noBase, inconsistentBase, busy, conflict, invalidRequest, notFound

    var code: String {
        switch self {
        case .remoteTarget: "remote_target"
        case .noBase: "no_base"
        case .inconsistentBase: "inconsistent_base"
        case .busy: "busy"
        case .conflict: "conflict"
        case .invalidRequest: "invalid_request"
        case .notFound: "not_found"
        }
    }

    var errorDescription: String? {
        switch self {
        case .remoteTarget: "Rule management is available only for the local core."
        case .noBase: "No base configuration is selected."
        case .inconsistentBase: "The selected and effective base configurations differ."
        case .busy: "Another configuration or core operation is in progress."
        case .conflict: "Configuration changed. Read the latest rules before retrying."
        case .invalidRequest: "Invalid action or rule fields."
        case .notFound: "Custom rule not found."
        }
    }
}
