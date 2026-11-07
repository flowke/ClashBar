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
        XCTAssertEqual(yaml["rules"]?.sequence?.compactMap(\.string), [
            "DOMAIN,new.example,DIRECT", "DOMAIN,a.example,Proxy", "MATCH,Proxy",
        ])
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
