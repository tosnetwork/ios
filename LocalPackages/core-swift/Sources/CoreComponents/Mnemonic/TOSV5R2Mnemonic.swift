import Foundation
import CryptoKit
import CommonCrypto
import TonSwift

/// Native master mapping. This does not construct a classical signing key.
public enum TOSV5R2Mnemonic {
    private static func derive(_ source: Data, salt: String, rounds: UInt32) throws -> Data {
        var output = Data(count: 64)
        let saltBytes = Data(salt.utf8)
        let status = source.withUnsafeBytes { key in saltBytes.withUnsafeBytes { s in
            output.withUnsafeMutableBytes { out in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    key.bindMemory(to: Int8.self).baseAddress, source.count,
                    s.bindMemory(to: UInt8.self).baseAddress, saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), rounds,
                    out.bindMemory(to: UInt8.self).baseAddress, 64)
            }
        }}
        guard status == kCCSuccess else {
            output.resetBytes(in: 0..<output.count)
            throw TOSPQError.invalidInput
        }
        return output
    }
    /// Password contains exact UTF-8 bytes and is consumed on every return path.
    /// Caller must protect and wipe the returned master. Twelve-word restores retain their original entropy.
    public static func masterAndWipePassword(words: [String], password: inout Data) throws -> Data {
        defer { password.resetBytes(in: 0..<password.count) }
        let normalized = words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard [12, 24].contains(normalized.count),
              normalized.allSatisfy({ TonSwift.Mnemonic.words.contains($0) }),
              String(data: password, encoding: .utf8) != nil else { throw TOSPQError.invalidInput }
        var phrase = Data(normalized.joined(separator: " ").utf8)
        defer { phrase.resetBytes(in: 0..<phrase.count) }
        var entropy = Data(HMAC<SHA512>.authenticationCode(for: password, using: SymmetricKey(data: phrase)))
        defer { entropy.resetBytes(in: 0..<entropy.count) }
        var validation = try derive(entropy, salt: "TOS seed version", rounds: 390)
        defer { validation.resetBytes(in: 0..<validation.count) }
        guard validation[0] == 0 else { throw TOSPQError.invalidInput }
        var derived = try derive(entropy, salt: "TOS default seed", rounds: 100_000)
        defer { derived.resetBytes(in: 0..<derived.count) }
        return Data(derived.prefix(32))
    }
}
