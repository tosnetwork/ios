import KeeperCore
import TonSwift
import XCTest

final class TOSPrivacyWithdrawalRecipientTests: XCTestCase {
    func testTestOnlyAddressCannotBeUsedOnMainnet() throws {
        let address = try Address.parse("0:" + String(repeating: "22", count: 32))
        for bounceable in [true, false] {
            let input = address.toFriendly(testOnly: true, bounceable: bounceable).toString()
            XCTAssertEqual(try Address.parse(input), address)
            XCTAssertThrowsError(try TOSPrivacyWithdrawalRecipient.parse(input, network: .mainnet))
            XCTAssertEqual(try TOSPrivacyWithdrawalRecipient.parse(input, network: .testnet), address)
        }
    }

    func testRawAndUnrestrictedFriendlyAddressesRetainExistingSemantics() throws {
        let raw = "0:" + String(repeating: "22", count: 32)
        let address = try Address.parse(raw)
        for network in [Network.mainnet, .testnet] {
            for input in [raw, address.toFriendly(testOnly: false, bounceable: true).toString(),
                          address.toFriendly(testOnly: false, bounceable: false).toString()] {
                XCTAssertEqual(try TOSPrivacyWithdrawalRecipient.parse(input, network: network), address)
            }
        }
    }

    func testMalformedAndOtherWorkchainAddressesAreRejected() {
        for input in ["invalid", "-1:" + String(repeating: "22", count: 32)] {
            XCTAssertThrowsError(try TOSPrivacyWithdrawalRecipient.parse(input, network: .mainnet))
            XCTAssertThrowsError(try TOSPrivacyWithdrawalRecipient.parse(input, network: .testnet))
        }
    }
}
