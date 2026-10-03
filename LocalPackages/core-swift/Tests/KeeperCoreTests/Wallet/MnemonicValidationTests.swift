import CoreComponents
@testable import KeeperCore
import TonSwift
import XCTest

final class MnemonicValidationTests: XCTestCase {
    func testDeterministicLegacyWalletMnemonicPreservesExpectedAddress() throws {
        let words = "mansion chef affair ancient announce police snap machine vanish liberty peace tennis effort recall law limit mosquito tornado toward advance vibrant bachelor auction voice".split(separator: " ").map(String.init)
        XCTAssertTrue(TOSV1MnemonicValidator.isValid(words))
        let pair = try MnemonicLegacy.anyMnemonicToPrivateKey(mnemonicArray: words)
        let wallet = Wallet(
            id: "fixture",
            identity: WalletIdentity(network: .mainnet, kind: .Regular(pair.publicKey, .v5R1)),
            metaData: WalletMetaData(label: "Fixture", tintColor: .defaultColor, icon: .icon(.wallet)),
            setupSettings: WalletSetupSettings(),
            batterySettings: BatterySettings()
        )
        XCTAssertEqual(
            try wallet.friendlyAddress.toString(),
            "UQCJFahawZUzYka4uzFTeWns-oQNfoa0VNVOAn8e8BJnXPZe"
        )
    }

    func testCurrentTOSMnemonicDerivesSDKCompatibleWalletAddress() throws {
        let words = "enhance depend evolve rotate creek total enable settle mammal margin round cube truck quote hold correct provide voyage north model sure off strategy pulse".split(separator: " ").map(String.init)
        XCTAssertTrue(TOSV1MnemonicValidator.isValid(words))
        XCTAssertTrue(TOSMnemonic.isValid(words))
        XCTAssertFalse(TonSwift.Mnemonic.mnemonicValidate(mnemonicArray: words))
        let pair = try TOSMnemonic.keyPair(words: words)
        XCTAssertEqual(pair.publicKey.data, try XCTUnwrap(Data(hex: "a71563f5709a827fad271813afc670403589781f4ac7259c7b0282b6686b2589")))
        let wallet = Wallet(id: "fixture", identity: WalletIdentity(network: .mainnet, kind: .Regular(pair.publicKey, .currentVersion), networkGlobalId: 3), metaData: WalletMetaData(label: "Fixture", tintColor: .defaultColor, icon: .icon(.wallet)), setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
        XCTAssertEqual(try wallet.address.toRaw(), "0:88269a9a5ecb30262608e6fb86f8ae3d534e8c77d5a9ae0140ce5217196a0cfe")
        XCTAssertEqual(try WalletMnemonic.keyPair(words: words, wallet: wallet).privateKey.data, pair.privateKey.data)
    }

    func testGeneratedNativeWalletPhrasesHaveExpectedCountAndValidate() throws {
        for _ in 0 ..< 20 {
            let words = TOSMnemonic.generate()
            XCTAssertEqual(words.count, 24)
            XCTAssertTrue(TOSMnemonic.isValid(words))
            XCTAssertTrue(TOSV1MnemonicValidator.isValid(words))
            XCTAssertNoThrow(try CoreComponents.Mnemonic(mnemonicWords: words))
        }
    }

    func testInvalidNativeWordCountsAreRejected() {
        let validWords = TonSwift.Mnemonic.mnemonicNew()

        XCTAssertThrowsError(try CoreComponents.Mnemonic(mnemonicWords: Array(validWords.prefix(23))))
        XCTAssertThrowsError(try CoreComponents.Mnemonic(mnemonicWords: validWords + [validWords[0]]))
    }

    func testTruncatedNativeMnemonicIsDeterministicallyRejected() {
        let validWords = TonSwift.Mnemonic.mnemonicNew()
        let truncatedWords = Array(validWords.prefix(23))

        for offset in 0 ..< 1_024 {
            let rotation = offset % truncatedWords.count
            let candidate = Array(truncatedWords[rotation...] + truncatedWords[..<rotation])
            XCTAssertThrowsError(try CoreComponents.Mnemonic(mnemonicWords: candidate))
        }
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
