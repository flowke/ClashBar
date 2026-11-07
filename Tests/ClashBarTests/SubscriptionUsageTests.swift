import XCTest
@testable import ClashBar

final class SubscriptionUsageTests: XCTestCase {
    func testParsesUsageAndExpiry() throws {
        let usage = try XCTUnwrap(SubscriptionUsage.parse("upload=100; download=250; total=1000; expire=1893456000"))
        XCTAssertEqual(usage.used, 350)
        XCTAssertEqual(usage.total, 1000)
        XCTAssertEqual(usage.expiresAt?.timeIntervalSince1970, 1893456000)
    }

    func testIncompleteAndOverflowValuesRemainUnavailable() throws {
        let usage = try XCTUnwrap(SubscriptionUsage.parse("upload=9223372036854775807; download=1; total=-1; expire=0"))
        XCTAssertNil(usage.used)
        XCTAssertNil(usage.total)
        XCTAssertNil(usage.expiresAt)
        XCTAssertNil(SubscriptionUsage.parse(nil))
    }
}
