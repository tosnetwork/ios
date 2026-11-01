@testable import KeeperCore
import TonSwift
import XCTest

final class TOSTokenRPCTests: XCTestCase {
    func testTokenListUsesTheNodeContract() throws {
        XCTAssertEqual(TOSTokenRPC.accountTokensMethod, "getAccountTokens")
        let entries = try TOSTokenRPC.positions(["tokens": [["token_master": "0:master", "token_wallet": "0:wallet"]]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].master, "0:master")
        XCTAssertEqual(entries[0].wallet, "0:wallet")
        XCTAssertTrue(try TOSTokenRPC.positions(["tokens": [[String: Any]]()]).isEmpty)
    }

    func testOldOrMalformedTokenListsAreNotAnEmptyBalance() {
        XCTAssertThrowsError(try TOSTokenRPC.positions(["jettons": []]))
        XCTAssertThrowsError(try TOSTokenRPC.positions(["tokens": [["jetton_master": "0:master", "jetton_wallet": "0:wallet"]]]))
        XCTAssertThrowsError(try TOSTokenRPC.positions(["tokens": NSNull()]))
    }

    func testMasterMetadataAndCommittedDecimals() throws {
        XCTAssertEqual(try TOSTokenRPC.metadataURI(["@type": "ext.tokens.tokenMasterData", "token_metadata_uri": "https://example.invalid/credit.json"]), "https://example.invalid/credit.json")
        let info = try TOSTokenRPC.masterInfo([
            "@type": "ext.tokens.tokenMasterData", "token_name": "Credit", "token_symbol": "CR",
            "token_decimals": "6", "token_image": "https://example.invalid/credit.png",
        ], address: address(), offchain: ["name": "Other", "decimals": "8"])
        XCTAssertEqual(info.name, "Credit")
        XCTAssertEqual(info.symbol, "CR")
        XCTAssertEqual(info.fractionDigits, 6)
        XCTAssertEqual(info.imageURL?.absoluteString, "https://example.invalid/credit.png")
    }

    func testMissingDecimalsUseOffchainValueThenDefaultToNine() throws {
        let data: [String: Any] = ["@type": "ext.tokens.tokenMasterData"]
        XCTAssertEqual(try TOSTokenRPC.masterInfo(data, address: address(), offchain: ["decimals": "8"]).fractionDigits, 8)
        XCTAssertEqual(try TOSTokenRPC.masterInfo(data, address: address(), offchain: nil).fractionDigits, 9)
        XCTAssertEqual(try TOSTokenRPC.masterInfo(data.merging(["token_decimals": "invalid"]) { _, new in new }, address: address(), offchain: nil).fractionDigits, 9)
        XCTAssertThrowsError(try TOSTokenRPC.masterInfo(["@type": "ext.tokens.jettonMasterData"], address: address(), offchain: nil))
    }

    private func address() throws -> Address {
        try Address.parse("0:" + String(repeating: "11", count: 32))
    }
}
