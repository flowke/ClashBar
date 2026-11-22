import Foundation
import XCTest
import Yams
@testable import ClashBar

final class ConfigRuleMergerTests: XCTestCase {
    func testAddsReplacesAndDeletesRulesWithoutChangingOtherFields() throws {
        let input = Data("mode: rule\nrules:\n  - DOMAIN,a.example,DIRECT\n  - DOMAIN,b.example,Proxy\n  - MATCH,Proxy\n".utf8)
        let changes = [
            CustomRuleChange(operation: .add, original: "", value: "DOMAIN,new.example,DIRECT"),
            CustomRuleChange(operation: .replace, original: "DOMAIN,a.example,DIRECT", value: "DOMAIN,a.example,Proxy"),
            CustomRuleChange(operation: .delete, original: "DOMAIN,b.example,Proxy", value: ""),
        ]
        let result = try ConfigRuleMerger().merge(input, changes: changes)
        let yaml = try XCTUnwrap(Yams.compose(yaml: String(decoding: result, as: UTF8.self)))
        XCTAssertEqual(yaml["mode"]?.string, "rule")
        XCTAssertEqual(yaml["profile"]?["store-selected"]?.scalar?.string, "true")
        XCTAssertEqual(yaml["rules"]?.sequence?.compactMap(\.string), [
            "DOMAIN,new.example,DIRECT", "DOMAIN,a.example,Proxy", "MATCH,Proxy",
        ])
    }

    func testDisabledChangesAreSkippedAndCanBeRestoredInPlace() throws {
        let input = Data("rules: ['DOMAIN,base.example,DIRECT', 'DOMAIN,old.example,DIRECT', 'MATCH,DIRECT']".utf8)
        var changes = [
            CustomRuleChange(operation: .add, original: "", value: "DOMAIN,first.example,DIRECT"),
            CustomRuleChange(operation: .add, original: "", value: "DOMAIN,second.example,DIRECT", isEnabled: false),
            CustomRuleChange(operation: .add, original: "", value: "DOMAIN,third.example,DIRECT"),
            CustomRuleChange(operation: .replace, original: "DOMAIN,base.example,DIRECT", value: "DOMAIN,base.example,REJECT", isEnabled: false),
            CustomRuleChange(operation: .delete, original: "DOMAIN,old.example,DIRECT", value: "", isEnabled: false),
        ]
        let merger = ConfigRuleMerger()
        XCTAssertEqual(try merger.rules(in: merger.merge(input, changes: changes)), [
            "DOMAIN,first.example,DIRECT", "DOMAIN,third.example,DIRECT",
            "DOMAIN,base.example,DIRECT", "DOMAIN,old.example,DIRECT", "MATCH,DIRECT",
        ])
        for index in changes.indices { changes[index].isEnabled = true }
        XCTAssertEqual(try merger.rules(in: merger.merge(input, changes: changes)), [
            "DOMAIN,first.example,DIRECT", "DOMAIN,second.example,DIRECT", "DOMAIN,third.example,DIRECT",
            "DOMAIN,base.example,REJECT", "MATCH,DIRECT",
        ])
    }

    func testSelectionPersistencePreservesOtherProfileSettings() throws {
        let input = Data("profile:\n  store-selected: false\n  store-fake-ip: true\nrules: ['MATCH,DIRECT']\n".utf8)
        let merged = try ConfigRuleMerger().merge(input, changes: [])
        let yaml = try XCTUnwrap(Yams.compose(yaml: String(decoding: merged, as: UTF8.self)))
        XCTAssertEqual(yaml["profile"]?["store-selected"]?.scalar?.string, "true")
        XCTAssertEqual(yaml["profile"]?["store-fake-ip"]?.scalar?.string, "true")
        XCTAssertNil(try ConfigRuleMerger().enablingSelectionPersistence(merged))
        let migrated = try XCTUnwrap(ConfigRuleMerger().enablingSelectionPersistence(input))
        let migratedYAML = try XCTUnwrap(Yams.compose(yaml: String(decoding: migrated, as: UTF8.self)))
        XCTAssertEqual(migratedYAML["profile"]?["store-selected"]?.scalar?.string, "true")
        XCTAssertEqual(migratedYAML["profile"]?["store-fake-ip"]?.scalar?.string, "true")
    }

    func testRejectsMissingOriginalInsteadOfSilentlyApplyingWrongRule() {
        let input = Data("rules: ['MATCH,DIRECT']\n".utf8)
        var change = CustomRuleChange(operation: .delete, original: "DOMAIN,missing,DIRECT", value: "")
        XCTAssertThrowsError(try ConfigRuleMerger().merge(input, changes: [change]))
        change.isEnabled = false
        XCTAssertNoThrow(try ConfigRuleMerger().merge(input, changes: [change]))
    }

    func testRejectsInvalidRules() {
        XCTAssertThrowsError(try ConfigRuleMerger().merge(Data("rules: nope".utf8), changes: []))
    }

    func testTestURLPersistsWithoutEnteringGeneratedRulesAndOldRecordsDecode() throws {
        let old = Data(#"{"operation":"add","original":"","value":"DOMAIN,example.com,DIRECT","id":"00000000-0000-0000-0000-000000000001"}"#.utf8)
        let decoded = try JSONDecoder().decode(CustomRuleChange.self, from: old)
        XCTAssertNil(decoded.testURL)
        XCTAssertTrue(decoded.isEnabled)
        var change = decoded
        change.testURL = "https://example.com/path"
        XCTAssertEqual(try JSONDecoder().decode(CustomRuleChange.self, from: JSONEncoder().encode(change)), change)
        let merged = try ConfigRuleMerger().merge(Data("rules: ['MATCH,DIRECT']".utf8), changes: [change])
        XCTAssertFalse(String(decoding: merged, as: UTF8.self).contains("https://example.com"))
    }

    func testDisabledRulePersistsAndIsExcludedFromTesting() throws {
        var change = CustomRuleChange(operation: .add, original: "", value: "DOMAIN,example.com,DIRECT",
                                      testURL: "https://example.com/path")
        XCTAssertTrue(RuleTester.canTest(change))
        change.isEnabled = false
        let restored = try JSONDecoder().decode(CustomRuleChange.self, from: JSONEncoder().encode(change))
        XCTAssertEqual(restored, change)
        XCTAssertFalse(RuleTester.canTest(restored))
    }

    func testRuleTestValidationAndConnectionEvidence() throws {
        XCTAssertNotNil(RuleTester.validURL("https://example.com/test"))
        XCTAssertNil(RuleTester.validURL("example.com"))
        XCTAssertNil(RuleTester.validURL("https://user:pass@example.com"))
        let json = Data(#"{"id":"abc","rule":"DomainSuffix","rulePayload":"example.com","chains":["node","Proxy"],"metadata":{"sourceIP":"127.0.0.1","sourcePort":"54321","host":"www.example.com"}}"#.utf8)
        let connection = try JSONDecoder().decode(ConnectionSummary.self, from: json)
        XCTAssertEqual(connection.metadata?.sourcePort, 54321)
        XCTAssertEqual(RuleTester.match(rule: "DOMAIN-SUFFIX,example.com,Proxy", connection: connection), .matched)
        XCTAssertEqual(RuleTester.match(rule: "DOMAIN-SUFFIX,example.com,DIRECT", connection: connection), .other)
        XCTAssertEqual(RuleTester.match(rule: "DOMAIN,example.com,Proxy", connection: connection), .other)
        XCTAssertEqual(RuleTester.match(rule: "DOMAIN,example.com,Proxy", connection: nil), .unknown)
        XCTAssertFalse(RuleTester.supports(CustomRuleChange(operation: .add, original: "", value: "PROCESS-NAME,app,DIRECT")))
        XCTAssertFalse(RuleTester.supports(CustomRuleChange(operation: .delete, original: "DOMAIN,example.com,DIRECT", value: "")))
    }

    @MainActor
    func testRuleBatchRunsTwentyAndRefillsAfterAnIndividualFailure() async {
        let rules = (1...21).map { index in
            CustomRuleChange(operation: .add, original: "", value: "DOMAIN,rule-\(index).example,DIRECT")
        }
        let gate = RuleMeasurementGate()
        var startedIDs: [UUID] = []
        var results: [UUID: RuleTestResult] = [:]
        let batch = Task {
            await RuleTester.runBatch(rules, measure: { rule in
                await gate.wait(for: rule.id)
                if rule.id == rules[0].id { throw RuleTestError.noProxyPort }
                return RuleTestResult(match: .matched, rule: rule.value, chain: ["DIRECT"], statusCode: 200,
                                      requestError: nil)
            }, started: { startedIDs.append($0) }, finished: { results[$0] = $1 })
        }

        let initialIDs = Set(rules.prefix(20).map(\.id))
        for _ in 0..<200 {
            if await gate.activeIDs == initialIDs { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let activeIDs = await gate.activeIDs
        XCTAssertEqual(activeIDs, initialIDs)
        XCTAssertEqual(startedIDs, Array(rules.prefix(20).map(\.id)))
        XCTAssertTrue(results.isEmpty)

        await gate.release(rules[0].id)
        let lastID = rules[20].id
        for _ in 0..<200 {
            if await gate.activeIDs.contains(lastID) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let refilledIDs = await gate.activeIDs
        XCTAssertEqual(refilledIDs, Set(rules.dropFirst().map(\.id)))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[rules[0].id]?.requestError, RuleTestError.noProxyPort.localizedDescription)

        await gate.releaseAll()
        await batch.value
        XCTAssertEqual(results.count, 21)
        XCTAssertEqual(results[lastID]?.rule, rules[20].value)
    }
}

private actor RuleMeasurementGate {
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<UUID> = []
    private var isOpen = false

    var activeIDs: Set<UUID> { Set(waiting.keys) }

    func wait(for id: UUID) async {
        guard !isOpen, !released.contains(id) else { return }
        await withCheckedContinuation { waiting[id] = $0 }
    }

    func release(_ id: UUID) {
        released.insert(id)
        waiting.removeValue(forKey: id)?.resume()
    }

    func releaseAll() {
        isOpen = true
        for continuation in waiting.values { continuation.resume() }
        waiting.removeAll()
    }
}
