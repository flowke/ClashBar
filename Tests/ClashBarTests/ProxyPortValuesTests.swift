import XCTest
@testable import ClashBar

final class ProxyPortValuesTests: XCTestCase {
    private func parse(_ yaml: String) throws -> ProxyPortValues {
        try ProxyPortValues.fromConfig(Data(yaml.utf8))
    }

    func testMissingPortsUseDefaultMixedPort() throws {
        let ports = try parse("mode: rule\n")
        XCTAssertEqual(ports.mixedPort, 7890)
        XCTAssertEqual(ports.port, 0)
    }

    func testExplicitDisabledPortsArePreserved() throws {
        let ports = try parse("mixed-port: 0\nport: 0\nsocks-port: 0\n")
        XCTAssertEqual(ports.mixedPort, 0)
        XCTAssertEqual(ports.port, 0)
        XCTAssertEqual(ports.socksPort, 0)
    }

    func testSeparateHTTPPortDoesNotEnableDefaultMixedPort() throws {
        let ports = try parse("port: 8888\nredir-port: 7892\n")
        XCTAssertEqual(ports.port, 8888)
        XCTAssertEqual(ports.mixedPort, 0)
        XCTAssertEqual(ports.redirPort, 7892)
    }

    func testInvalidPortIsRejected() {
        XCTAssertThrowsError(try parse("mixed-port: invalid\n"))
        XCTAssertThrowsError(try parse("mixed-port: 65536\n"))
    }

    func testReportsWhenCoreDoesNotApplyRequestedPort() {
        let desired = ProxyPortValues(port: 0, socksPort: 0, mixedPort: 7890, redirPort: 0, tproxyPort: 0)
        let actual = ProxyPortValues(port: 0, socksPort: 0, mixedPort: 0, redirPort: 0, tproxyPort: 0)
        let mismatch = ProxyPortValues.firstMismatch(in: desired.patch, actual: actual)
        XCTAssertEqual(mismatch?.key, "mixed-port")
        XCTAssertEqual(mismatch?.expected, 7890)
        XCTAssertEqual(mismatch?.actual, 0)
        XCTAssertNil(ProxyPortValues.firstMismatch(in: desired.patch, actual: desired))
    }
}
