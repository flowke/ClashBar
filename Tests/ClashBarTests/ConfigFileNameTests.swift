import Foundation
import XCTest
@testable import ClashBar

final class ConfigFileNameTests: XCTestCase {
    func testSubscriptionNameUsesHostRatherThanPathOrQuery() throws {
        let service = ConfigImportService()
        let url = try XCTUnwrap(URL(string: "https://example.com/config.yaml?token=secret"))
        XCTAssertEqual(service.inferredRemoteConfigFileName(from: url), "example.com.yaml")
        XCTAssertEqual(service.normalizedConfigFileName("", fallback: service.inferredRemoteConfigFileName(from: url)), "example.com.yaml")
        XCTAssertEqual(service.normalizedConfigFileName("custom", fallback: service.inferredRemoteConfigFileName(from: url)), "custom.yaml")
    }

    func testEmbeddedSubscriptionDisplayNameIsPreferredAndScopedToMetadata() {
        let service = ConfigImportService()
        let named = Data("name: 火箭TNT\nproxies:\n  - name: 节点一\n".utf8)
        XCTAssertEqual(service.inferredRemoteConfigDisplayName(from: named), "火箭TNT")
        XCTAssertEqual(service.inferredRemoteConfigDisplayName(from: Data("name: 火箭TNT.yaml\n".utf8)), "火箭TNT")

        let metadata = Data("metadata:\n  title: 我的套餐\nproxy-groups:\n  - name: 节点组\n".utf8)
        XCTAssertEqual(service.inferredRemoteConfigDisplayName(from: metadata), "我的套餐")

        let onlyProxyNames = Data("proxies:\n  - name: 节点一\nproxy-groups:\n  - name: 节点组\n".utf8)
        XCTAssertNil(service.inferredRemoteConfigDisplayName(from: onlyProxyNames))
    }

    func testEmbeddedSubscriptionDisplayNameRejectsPathLikeValues() {
        let service = ConfigImportService()
        XCTAssertNil(service.inferredRemoteConfigDisplayName(from: Data("name: ../private\n".utf8)))
        XCTAssertNil(service.inferredRemoteConfigDisplayName(from: Data("name: \"https://example.com\"\n".utf8)))
        XCTAssertNil(service.inferredRemoteConfigDisplayName(from: Data("name: '   '\n".utf8)))
    }
}
