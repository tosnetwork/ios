import CoreComponents
import TonSwift

public enum WalletMnemonicFormat: Equatable {
    case tos
    case legacyTON

    public enum Error: Swift.Error {
        case invalidPhrase
        case ambiguousPhrase
    }

    public static func validFormats(words: [String]) -> [WalletMnemonicFormat] {
        let words = TOSV1MnemonicValidator.normalize(words)
        var formats = [WalletMnemonicFormat]()
        if TOSMnemonic.isValid(words) { formats.append(.tos) }
        if words.count == 24 && TonSwift.Mnemonic.mnemonicValidate(mnemonicArray: words) { formats.append(.legacyTON) }
        return formats
    }

    public static func detect(words: [String]) throws -> WalletMnemonicFormat {
        let formats = validFormats(words: words)
        guard !formats.isEmpty else { throw Error.invalidPhrase }
        guard formats.count == 1 else { throw Error.ambiguousPhrase }
        return formats[0]
    }

    public func keyPair(words: [String]) throws -> KeyPair {
        let words = TOSV1MnemonicValidator.normalize(words)
        switch self {
        case .tos: return try TOSMnemonic.keyPair(words: words)
        case .legacyTON: return try MnemonicLegacy.anyMnemonicToPrivateKey(mnemonicArray: words)
        }
    }
}

public enum WalletMnemonic {
    public static func keyPair(words: [String], wallet: Wallet) throws -> KeyPair {
        let format: WalletMnemonicFormat = try wallet.contractVersion == .tosV5R1 ? .tos : .legacyTON
        let pair = try format.keyPair(words: words)
        guard pair.publicKey.data == (try wallet.publicKey).data else { throw WalletMnemonicFormat.Error.invalidPhrase }
        return pair
    }
}
