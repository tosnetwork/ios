import CoreComponents
@testable import KeeperCore
import TonSwift
import XCTest

final class MnemonicValidationTests: XCTestCase {
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
}
