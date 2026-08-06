import CoreComponents
@testable import KeeperCore
import TonSwift
import XCTest

final class MnemonicValidationTests: XCTestCase {
    func testDeterministicNativeTOSMnemonicDerivesExpectedAddress() throws {
        let words = "mansion chef affair ancient announce police snap machine vanish liberty peace tennis effort recall law limit mosquito tornado toward advance vibrant bachelor auction voice".split(separator: " ").map(String.init)
        XCTAssertTrue(TOSV1MnemonicValidator.isValid(words))
        let pair = try MnemonicLegacy.anyMnemonicToPrivateKey(mnemonicArray: words)
        let wallet = Wallet(
            id: "fixture",
            identity: WalletIdentity(network: .mainnet, kind: .Regular(pair.publicKey, .currentVersion)),
            metaData: WalletMetaData(label: "Fixture", tintColor: .defaultColor, icon: .icon(.wallet)),
            setupSettings: WalletSetupSettings(),
            batterySettings: BatterySettings()
        )
        XCTAssertEqual(
            try wallet.friendlyAddress.toString(),
            "UQCJFahawZUzYka4uzFTeWns-oQNfoa0VNVOAn8e8BJnXPZe"
        )
    }

    func testGeneratedNativeWalletPhrasesHaveExpectedCountAndValidate() throws {
        for _ in 0 ..< 20 {
            let words = TonSwift.Mnemonic.mnemonicNew()
            XCTAssertEqual(words.count, 24)
            XCTAssertTrue(TonSwift.Mnemonic.mnemonicValidate(mnemonicArray: words))
            XCTAssertTrue(TOSV1MnemonicValidator.isValid(words))
            XCTAssertNoThrow(try CoreComponents.Mnemonic(mnemonicWords: words))
        }
    }

    func testInvalidWordCountIsRejected() {
        let words = Array(TonSwift.Mnemonic.mnemonicNew().prefix(23))
        XCTAssertThrowsError(try CoreComponents.Mnemonic(mnemonicWords: words))
    }

    func testUnknownWordIsRejected() {
        var words = TonSwift.Mnemonic.mnemonicNew()
        words[0] = "not-a-mnemonic-word"
        XCTAssertThrowsError(try CoreComponents.Mnemonic(mnemonicWords: words))
        XCTAssertFalse(TOSV1MnemonicValidator.isValid(words))
    }

    func testLegacyPhraseWithoutNativeTOSChecksumIsRejectedByV1() {
        let words = Array(repeating: "abandon", count: 24)
        XCTAssertTrue(MnemonicLegacy.isValidBip39Mnemonic(mnemonicArray: words))
        XCTAssertFalse(TonSwift.Mnemonic.mnemonicValidate(mnemonicArray: words))
        XCTAssertFalse(TOSV1MnemonicValidator.isValid(words))
    }

    func testV1MnemonicNormalizesWhitespaceNewlinesAndCapitalization() {
        let canonical = "mansion chef affair ancient announce police snap machine vanish liberty peace tennis effort recall law limit mosquito tornado toward advance vibrant bachelor auction voice"
        let decorated = "  MANSION\tChef  affair\nancient announce police snap machine vanish liberty peace tennis effort recall law limit mosquito tornado toward advance vibrant bachelor auction VOICE  "
        XCTAssertEqual(TOSV1MnemonicValidator.normalize(decorated), canonical.split(separator: " ").map(String.init))
        XCTAssertTrue(TOSV1MnemonicValidator.isValid(TOSV1MnemonicValidator.normalize(decorated)))
    }
}
