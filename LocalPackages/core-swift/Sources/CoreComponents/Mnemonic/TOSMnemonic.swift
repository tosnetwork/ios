import Foundation
import TonSwift
import TweetNacl

/// The TOS SDK mnemonic domain. Existing TON mnemonics keep their original domain.
public enum TOSMnemonic {
    public static func isValid(_ words: [String]) -> Bool {
        let words = normalize(words)
        guard words.count == 24, words.allSatisfy({ TonSwift.Mnemonic.words.contains($0) }) else { return false }
        let entropy = hmacSha512(phrase: words.joined(separator: " "), password: "")
        return pbkdf2Sha512(phrase: entropy, salt: Data("TOS seed version".utf8), iterations: 390, keyLength: 64)[0] == 0
    }

    public static func generate() -> [String] {
        var generator = SystemRandomNumberGenerator()
        while true {
            let words = (0..<24).map { _ in TonSwift.Mnemonic.words.randomElement(using: &generator)! }
            if isValid(words) { return words }
        }
    }

    public static func keyPair(words: [String]) throws -> KeyPair {
        let words = normalize(words)
        guard isValid(words) else { throw Mnemonic.Error.incorrectMnemonicWords }
        let entropy = hmacSha512(phrase: words.joined(separator: " "), password: "")
        let seed = Data(pbkdf2Sha512(phrase: entropy, salt: Data("TOS default seed".utf8), iterations: 100_000, keyLength: 64).prefix(32))
        let pair = try TweetNacl.NaclSign.KeyPair.keyPair(fromSeed: seed)
        return KeyPair(publicKey: .init(data: pair.publicKey), privateKey: .init(data: pair.secretKey))
    }

    private static func normalize(_ words: [String]) -> [String] {
        words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }
}
