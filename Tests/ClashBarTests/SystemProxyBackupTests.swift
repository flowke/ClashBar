import Foundation
import ProxyHelperShared
import XCTest

final class SystemProxyBackupTests: XCTestCase {
    private let clash = SystemProxyBackup.Target(host: "127.0.0.1", httpPort: 7890, httpsPort: 7890, socksPort: 7890)
    private let updatedClash = SystemProxyBackup.Target(host: "127.0.0.1", httpPort: 7891, httpsPort: 7891, socksPort: 7891)

    private func active(_ port: Int) -> [String: Any] {
        ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
         "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
         "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": port,
         "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
    }

    func testRestoresEachServiceAndPreservesUnrelatedChanges() throws {
        let original: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "example.com", "HTTPPort": 8888,
                                      "ProxyAutoConfigEnable": 1, "ExceptionsList": ["old.example"],
                                      "Unrelated": "before"]
        let backup = try SystemProxyBackup.prepare(previous: nil, current: ["wifi": original, "ethernet": [:]], target: clash)
        var owned = active(7890)
        owned["ExceptionsList"] = ["clash.example"]
        owned["Unrelated"] = "after"
        let restored = try XCTUnwrap(backup.restoredConfiguration(identifier: "wifi", current: owned))
        XCTAssertEqual(restored["HTTPProxy"] as? String, "example.com")
        XCTAssertEqual(restored["HTTPPort"] as? Int, 8888)
        XCTAssertEqual(restored["ProxyAutoConfigEnable"] as? Int, 1)
        XCTAssertEqual(restored["ExceptionsList"] as? [String], ["old.example"])
        XCTAssertNil(restored["SOCKSEnable"])
        XCTAssertEqual(restored["Unrelated"] as? String, "after")
        XCTAssertTrue(try XCTUnwrap(backup.restoredConfiguration(identifier: "ethernet", current: active(7890))).isEmpty)
    }

    func testPortUpdateKeepsOriginalButReclaimCapturesLatestSettings() throws {
        let first = try SystemProxyBackup.prepare(previous: nil, current: ["wifi": active(8888)], target: clash)
        let updated = try SystemProxyBackup.prepare(previous: first, current: ["wifi": active(7890)], target: updatedClash)
        let firstRestore = try XCTUnwrap(updated.restoredConfiguration(identifier: "wifi", current: active(7891)))
        XCTAssertEqual(firstRestore["HTTPPort"] as? Int, 8888)

        let reclaimed = try SystemProxyBackup.prepare(previous: updated, current: ["wifi": active(9999)], target: clash)
        let latestRestore = try XCTUnwrap(reclaimed.restoredConfiguration(identifier: "wifi", current: active(7890)))
        XCTAssertEqual(latestRestore["HTTPPort"] as? Int, 9999)
        XCTAssertNil(try reclaimed.restoredConfiguration(identifier: "wifi", current: active(9999)))
        XCTAssertNil(try reclaimed.restoredConfiguration(identifier: "unknown", current: active(7890)))
    }

    func testReclaimPreservesOriginalForServicesStillOwned() throws {
        let first = try SystemProxyBackup.prepare(
            previous: nil, current: ["wifi": active(8888), "ethernet": [:]], target: clash)
        let reclaimed = try SystemProxyBackup.prepare(
            previous: first, current: ["wifi": active(9999), "ethernet": active(7890)], target: clash)
        let wifi = try XCTUnwrap(reclaimed.restoredConfiguration(identifier: "wifi", current: active(7890)))
        let ethernet = try XCTUnwrap(reclaimed.restoredConfiguration(identifier: "ethernet", current: active(7890)))
        XCTAssertEqual(wifi["HTTPPort"] as? Int, 9999)
        XCTAssertTrue(ethernet.isEmpty)
    }
}
