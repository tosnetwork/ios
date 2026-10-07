import Foundation
import Security
import TOSPQNative

public enum TOSQuantumRole: Int32, Codable, Sendable {
    case primary = 1, rescue = 2
    public var seedSize: Int { Int(tos_quantum_seed_size(rawValue)) }
    public var publicKeySize: Int { Int(tos_quantum_public_key_size(rawValue)) }
    public var signatureSize: Int { Int(tos_quantum_signature_size(rawValue)) }
    public var entropySize: Int { Int(tos_quantum_entropy_size(rawValue)) }
}
public enum TOSQuantumPurpose: Int32, Sendable { case auth = 1, pop = 2, preparation = 3 }

/// Stateless PQ primitive. The wallet service must bind live proofs and durable fee state.
public enum TOSQuantumSigner {
    public static func publicKey(role: TOSQuantumRole, seed: Data) throws -> Data {
        guard seed.count == role.seedSize else { throw TOSPQError.invalidInput }
        var key = Data(count: role.publicKeySize)
        let rc = seed.withUnsafeBytes { s in key.withUnsafeMutableBytes { k in
            tos_quantum_public_key(role.rawValue, s.bindMemory(to: UInt8.self).baseAddress, seed.count,
                k.bindMemory(to: UInt8.self).baseAddress, role.publicKeySize)
        }}
        guard rc == 0 else { throw TOSPQError.signingFailure }
        return key
    }
    public static func sign(role: TOSQuantumRole, purpose: TOSQuantumPurpose, seed: Data,
                            expectedPublicKey: Data, digest: Data) throws -> Data {
        guard digest.count == 32, !(role == .primary && purpose == .preparation) else { throw TOSPQError.invalidInput }
        guard try publicKey(role: role, seed: seed) == expectedPublicKey else { throw TOSPQError.keyBinding }
        var entropy = Data(count: role.entropySize)
        defer { entropy.resetBytes(in: 0..<entropy.count) }
        let randomStatus = entropy.withUnsafeMutableBytes { p -> OSStatus in
            guard let address = p.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, role.entropySize, address)
        }
        guard randomStatus == errSecSuccess else { throw TOSPQError.entropyFailure }
        var signature = Data(count: role.signatureSize)
        let rc = seed.withUnsafeBytes { s in entropy.withUnsafeBytes { e in digest.withUnsafeBytes { d in
            signature.withUnsafeMutableBytes { sig in
                tos_quantum_sign(role.rawValue, purpose.rawValue, s.bindMemory(to: UInt8.self).baseAddress, seed.count,
                    e.bindMemory(to: UInt8.self).baseAddress, role.entropySize,
                    d.bindMemory(to: UInt8.self).baseAddress, digest.count,
                    sig.bindMemory(to: UInt8.self).baseAddress, role.signatureSize)
            }
        }}}
        guard rc == 0, verify(role: role, purpose: purpose, publicKey: expectedPublicKey, digest: digest, signature: signature) else {
            signature.resetBytes(in: 0..<signature.count)
            throw TOSPQError.signingFailure
        }
        return signature
    }
    public static func verify(role: TOSQuantumRole, purpose: TOSQuantumPurpose, publicKey: Data, digest: Data, signature: Data) -> Bool {
        guard publicKey.count == role.publicKeySize, digest.count == 32, signature.count == role.signatureSize else { return false }
        return publicKey.withUnsafeBytes { k in digest.withUnsafeBytes { d in signature.withUnsafeBytes { s in
            tos_quantum_verify(role.rawValue, purpose.rawValue, k.bindMemory(to: UInt8.self).baseAddress, publicKey.count,
                d.bindMemory(to: UInt8.self).baseAddress, digest.count, s.bindMemory(to: UInt8.self).baseAddress, signature.count) == 1
        }}}
    }
}

/// Pure fee signature verification. Enrollment, expiry and broadcast require authenticated chain state.
public enum TOSQuantumFeeVerifier {
    public static func verify(leaf: UInt32, publicKey: Data, digest: Data, signature: Data) -> Bool {
        guard leaf < (1 << 20), publicKey.count == 60, digest.count == 32, signature.count == 2832 else { return false }
        return publicKey.withUnsafeBytes { k in digest.withUnsafeBytes { d in signature.withUnsafeBytes { s in
            tos_wallet_lms_fee_verify(leaf, d.bindMemory(to: UInt8.self).baseAddress, 32,
                s.bindMemory(to: UInt8.self).baseAddress, 2832, k.bindMemory(to: UInt8.self).baseAddress, 60) == 1
        }}}
    }
}
