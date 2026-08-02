@testable import KeeperCore
import XCTest

final class TOSRPCSettingsTests: XCTestCase {
    override func tearDown() {
        TOSRPCSettings.reset()
        super.tearDown()
    }

    func testAddsHTTPToHostAndPort() throws {
        XCTAssertEqual(
            try TOSRPCSettings.setCustomEndpoint("192.168.1.20:18545"),
            "http://192.168.1.20:18545"
        )
    }

    func testAcceptsHTTPSAndRemovesJSONRPCSuffix() throws {
        XCTAssertEqual(
            try TOSRPCSettings.setCustomEndpoint("https://node.example/jsonRPC/"),
            "https://node.example"
        )
    }

    func testRejectsCredentialsAndUnsupportedSchemes() {
        XCTAssertThrowsError(try TOSRPCSettings.setCustomEndpoint("ftp://node.example"))
        XCTAssertThrowsError(try TOSRPCSettings.setCustomEndpoint("http://user:password@node.example"))
    }

    func testEmptyValueRestoresDefault() throws {
        try TOSRPCSettings.setCustomEndpoint("localhost:18545")
        XCTAssertNil(try TOSRPCSettings.setCustomEndpoint("  "))
        XCTAssertNil(TOSRPCSettings.customEndpoint)
    }
}
