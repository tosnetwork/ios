import CoreComponents
@testable import KeeperCore
import TonSwift
import XCTest

final class TOSMnemonicDomainTests: XCTestCase {
    func testKeyDerivationAndPhraseDetectionMatchIndependentSDKGoldens() throws {
        let data = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "tos-mnemonic-goldens", withExtension: "json")))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for vector in try XCTUnwrap(fixture["vectors"] as? [[String: Any]]) {
            let words = try XCTUnwrap(vector["mnemonic"] as? String).split(separator: " ").map(String.init)
            let tosValid = try XCTUnwrap(vector["tos_valid"] as? Bool)
            let tonValid = try XCTUnwrap(vector["ton_valid"] as? Bool)
            XCTAssertEqual(TOSMnemonic.isValid(words), tosValid)
            XCTAssertEqual(TonSwift.Mnemonic.mnemonicValidate(mnemonicArray: words), tonValid)
            if tosValid {
                let expected = try XCTUnwrap(vector["TOS"] as? [String: Any])
                let pair = try TOSMnemonic.keyPair(words: words)
                XCTAssertEqual(pair.publicKey.data, try XCTUnwrap(Data(hex: XCTUnwrap(expected["public_key_hex"] as? String))))
                XCTAssertEqual(pair.privateKey.data, try XCTUnwrap(Data(hex: XCTUnwrap(expected["secret_key64_hex"] as? String))))
                let decorated = words.map { " \($0.uppercased())\n" }
                XCTAssertTrue(TOSMnemonic.isValid(decorated))
                XCTAssertEqual(try TOSMnemonic.keyPair(words: decorated).privateKey.data, pair.privateKey.data)
            }
            if tonValid {
                let expected = try XCTUnwrap(vector["TON"] as? [String: Any])
                let pair = try WalletMnemonicFormat.legacyTON.keyPair(words: words)
                XCTAssertEqual(pair.publicKey.data, try XCTUnwrap(Data(hex: XCTUnwrap(expected["public_key_hex"] as? String))))
                XCTAssertEqual(pair.privateKey.data, try XCTUnwrap(Data(hex: XCTUnwrap(expected["secret_key64_hex"] as? String))))
                let legacy = WalletV5R1(publicKey: pair.publicKey.data, walletId: WalletId(networkGlobalId: -239))
                XCTAssertEqual(try legacy.address().toRaw(), expected["legacy_v5_mainnet_address"] as? String)
            }
            if tosValid && tonValid { XCTAssertThrowsError(try WalletMnemonicFormat.detect(words: words)) }
            else { XCTAssertEqual(try WalletMnemonicFormat.detect(words: words), tosValid ? .tos : .legacyTON) }
        }
    }

    func testRestoredLegacyIdentityKeepsItsOriginalSigningKey() throws {
        let words = "mansion chef affair ancient announce police snap machine vanish liberty peace tennis effort recall law limit mosquito tornado toward advance vibrant bachelor auction voice".split(separator: " ").map(String.init)
        let pair = try MnemonicLegacy.anyMnemonicToPrivateKey(mnemonicArray: words)
        XCTAssertEqual(pair.publicKey.data, try XCTUnwrap(Data(hex: "54298c04ae729978cb7c988270e86b20e00a752562411b3511634ec59beebf26")))
        let identity = WalletIdentity(network: .mainnet, kind: .Regular(pair.publicKey, .v5R1))
        let restored = try JSONDecoder().decode(WalletIdentity.self, from: JSONEncoder().encode(identity))
        let wallet = Wallet(id: "legacy", identity: restored, metaData: WalletMetaData(label: "Fixture", tintColor: .defaultColor, icon: .icon(.wallet)), setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
        XCTAssertEqual(try wallet.friendlyAddress.toString(), "UQCJFahawZUzYka4uzFTeWns-oQNfoa0VNVOAn8e8BJnXPZe")
        XCTAssertEqual(try WalletMnemonic.keyPair(words: words, wallet: wallet).privateKey.data, pair.privateKey.data)
        XCTAssertThrowsError(try TOSMnemonic.keyPair(words: words))
    }
}
