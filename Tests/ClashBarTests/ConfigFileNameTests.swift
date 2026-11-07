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
}
