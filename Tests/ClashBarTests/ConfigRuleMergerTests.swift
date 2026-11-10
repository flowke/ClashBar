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
}
