import Foundation
import XCTest
@testable import ClashBar

final class ConnectionsSnapshotTests: XCTestCase {
    func testDecodesConnectionCountAndServerTotals() throws {
        let data = Data(#"{"uploadTotal":1234,"downloadTotal":5678,"connections":[{"id":"one"},{"id":"two"}]}"#.utf8)
        let snapshot = try JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
        XCTAssertEqual(snapshot.totalCount, 2)
        XCTAssertEqual(snapshot.uploadTotal, 1234)
        XCTAssertEqual(snapshot.downloadTotal, 5678)
    }

    func testMissingTotalsRemainUnavailable() throws {
        let data = Data(#"{"connections":[]}"#.utf8)
        let snapshot = try JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
        XCTAssertEqual(snapshot.totalCount, 0)
        XCTAssertNil(snapshot.uploadTotal)
        XCTAssertNil(snapshot.downloadTotal)
    }
}
