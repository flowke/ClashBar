import XCTest
@testable import ClashBar

final class FormattersTests: XCTestCase {
    func testBytesGBPreserveTwoDecimalPlacesForLargeQuotas() {
        let gib: Int64 = 1024 * 1024 * 1024
        let preciseQuota = Int64((3847.07 * Double(gib)).rounded())

        XCTAssertEqual(ValueFormatter.bytesGBNoSpace(3_847 * gib), "3847GB")
        XCTAssertEqual(ValueFormatter.bytesGBNoSpace(preciseQuota), "3847.07GB")
    }
}
