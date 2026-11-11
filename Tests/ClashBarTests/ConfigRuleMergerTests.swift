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
        let input = Data("rules: [MATCH,DIRECT]\n".utf8)
        XCTAssertThrowsError(try ConfigRuleMerger().merge(input, changes: [
            CustomRuleChange(operation: .delete, original: "DOMAIN,missing,DIRECT", value: ""),
        ]))
    }

    func testRejectsInvalidRules() {
        XCTAssertThrowsError(try ConfigRuleMerger().merge(Data("rules: nope".utf8), changes: []))
    }

    func testTestURLPersistsWithoutEnteringGeneratedRulesAndOldRecordsDecode() throws {
        let old = Data(#"{"operation":"add","original":"","value":"DOMAIN,example.com,DIRECT","id":"00000000-0000-0000-0000-000000000001"}"#.utf8)
        let decoded = try JSONDecoder().decode(CustomRuleChange.self, from: old)
        XCTAssertNil(decoded.testURL)
        var change = decoded
        change.testURL = "https://example.com/path"
        XCTAssertEqual(try JSONDecoder().decode(CustomRuleChange.self, from: JSONEncoder().encode(change)), change)
        let merged = try ConfigRuleMerger().merge(Data("rules: ['MATCH,DIRECT']".utf8), changes: [change])
        XCTAssertFalse(String(decoding: merged, as: UTF8.self).contains("https://example.com"))
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
}
