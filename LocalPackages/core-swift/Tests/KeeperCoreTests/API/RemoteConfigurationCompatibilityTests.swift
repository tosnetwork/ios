@testable import KeeperCore
import XCTest

final class RemoteConfigurationCompatibilityTests: XCTestCase {
    func testDecodesLegacyTonkeeperKeys() throws {
        let configuration = try decode(
            """
            {
              "tonkeeperNewsUrl": "https://news.example.com",
              "tonkeeper_api_url": "https://api.example.com"
            }
            """
        )

        XCTAssertEqual(configuration.toswalletNewsUrl?.absoluteString, "https://news.example.com")
        XCTAssertEqual(configuration.toswalletApiUrl, "https://api.example.com")
    }

    func testTosWalletKeysTakePrecedenceDuringMigration() throws {
        let configuration = try decode(
            """
            {
              "toswalletNewsUrl": "https://new-news.example.com",
              "tonkeeperNewsUrl": "https://old-news.example.com",
              "toswallet_api_url": "https://new-api.example.com",
              "tonkeeper_api_url": "https://old-api.example.com"
            }
            """
        )

        XCTAssertEqual(configuration.toswalletNewsUrl?.absoluteString, "https://new-news.example.com")
        XCTAssertEqual(configuration.toswalletApiUrl, "https://new-api.example.com")
    }

    private func decode(_ json: String) throws -> RemoteConfiguration {
        try JSONDecoder().decode(RemoteConfiguration.self, from: XCTUnwrap(json.data(using: .utf8)))
    }
}
