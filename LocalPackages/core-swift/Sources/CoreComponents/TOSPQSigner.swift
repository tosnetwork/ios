import Foundation
import Security
import TOSPQNative

public enum TOSPQAlgorithm: Int32, Codable, Sendable {
    case mldsa44 = 1
    case falcon512Padded = 2
    public var minimumVM: Int { self == .mldsa44 ? 16 : 19 }
    public var publicKeySize: Int { Int(tos_pq_public_key_size(rawValue)) }
    public var signatureSize: Int { Int(tos_pq_signature_size(rawValue)) }
}
public enum TOSPQError: Error { case invalidInput, entropyFailure, signingFailure, keyBinding, keychain(OSStatus) }

/// Fixed AUTH profiles. Seeds are never logged; expanded secrets stay in native code.
public enum TOSPQSigner {
    public static var notices: String {
        guard let url = Bundle.module.url(forResource: "TOSPQNotices", withExtension: "txt"),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return value
    }
    public static func randomSeed() throws -> Data { try entropy(count: 32) }
    private static func entropy(count: Int) throws -> Data {
        var data = Data(count: count)
        guard data.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }) == errSecSuccess else {
            throw TOSPQError.entropyFailure
        }
        return data
    }
    public static func publicKey(algorithm: TOSPQAlgorithm, seed: Data) throws -> Data {
        guard seed.count == 32 else { throw TOSPQError.invalidInput }
        var pk = Data(count: algorithm.publicKeySize)
        let rc = seed.withUnsafeBytes { s in pk.withUnsafeMutableBytes { p in
            tos_pq_public_key(algorithm.rawValue, s.bindMemory(to: UInt8.self).baseAddress, 32,
                p.bindMemory(to: UInt8.self).baseAddress, algorithm.publicKeySize)
        }}
        guard rc == 0 else { throw TOSPQError.signingFailure }
        return pk
    }
    public static func sign(algorithm: TOSPQAlgorithm, seed: Data, expectedPublicKey: Data, message: Data) throws -> Data {
        guard try publicKey(algorithm: algorithm, seed: seed) == expectedPublicKey else { throw TOSPQError.keyBinding }
        var random = try entropy(count: 48)
        defer { random.resetBytes(in: 0..<random.count) }
        var signature = Data(count: algorithm.signatureSize)
        let rc = seed.withUnsafeBytes { s in random.withUnsafeBytes { r in message.withUnsafeBytes { m in
            signature.withUnsafeMutableBytes { sig in
                tos_pq_sign(algorithm.rawValue, s.bindMemory(to: UInt8.self).baseAddress, seed.count,
                    r.bindMemory(to: UInt8.self).baseAddress, random.count,
                    m.bindMemory(to: UInt8.self).baseAddress, message.count,
                    sig.bindMemory(to: UInt8.self).baseAddress, algorithm.signatureSize)
            }
        }}}
        guard rc == 0 else { throw TOSPQError.signingFailure }
        return signature
    }
    public static func verify(algorithm: TOSPQAlgorithm, publicKey: Data, message: Data, signature: Data) -> Bool {
        publicKey.withUnsafeBytes { p in message.withUnsafeBytes { m in signature.withUnsafeBytes { s in
            tos_pq_verify(algorithm.rawValue, p.bindMemory(to: UInt8.self).baseAddress, publicKey.count,
                m.bindMemory(to: UInt8.self).baseAddress, message.count,
                s.bindMemory(to: UInt8.self).baseAddress, signature.count) == 1
        }}}
    }
}

/// Non-synchronizing, device-only PQ seed records; OS user presence gates retrieval.
/// No silent fallback if device passcode or user-presence protection is unavailable.
public final class TOSPQSeedKeychain {
    private let service = "network.tos.wallet.pq.seed.v1"
    public init() {}
    private func query(id: UUID, algorithm: TOSPQAlgorithm) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: "\(algorithm.rawValue).\(id.uuidString)", kSecAttrSynchronizable: false]
    }
    public func create(id: UUID, algorithm: TOSPQAlgorithm) throws -> Data {
        var seed = try TOSPQSigner.randomSeed()
        defer { seed.resetBytes(in: 0..<seed.count) }
        return try restore(id: id, algorithm: algorithm, seed: seed)
    }
    public func restore(id: UUID, algorithm: TOSPQAlgorithm, seed: Data) throws -> Data {
        let pk = try TOSPQSigner.publicKey(algorithm: algorithm, seed: seed)
        var q = query(id: id, algorithm: algorithm)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                          .userPresence, &error) else { throw TOSPQError.invalidInput }
        q[kSecAttrAccessControl] = access
        q[kSecValueData] = seed
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw TOSPQError.keychain(status) }
        return pk
    }
    public func sign(id: UUID, algorithm: TOSPQAlgorithm, expectedPublicKey: Data, message: Data) throws -> Data {
        var q = query(id: id, algorithm: algorithm)
        q[kSecReturnData] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        guard status == errSecSuccess, var seed = value as? Data else { throw TOSPQError.keychain(status) }
        defer { seed.resetBytes(in: 0..<seed.count) }
        return try TOSPQSigner.sign(algorithm: algorithm, seed: seed, expectedPublicKey: expectedPublicKey, message: message)
    }
    public func backup(id: UUID, algorithm: TOSPQAlgorithm, network: Int32, expectedPublicKey: Data, password: String) throws -> Data {
        var q = query(id: id, algorithm: algorithm); q[kSecReturnData] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        guard status == errSecSuccess, var seed = value as? Data else { throw TOSPQError.keychain(status) }
        defer { seed.resetBytes(in: 0..<seed.count) }
        return try TOSPQBackup.encrypt(algorithm: algorithm, network: network, publicKey: expectedPublicKey, seed: seed, password: password)
    }
    public func restoreBackup(id: UUID, algorithm: TOSPQAlgorithm, network: Int32, record: Data, password: String) throws -> Data {
        var seed = try TOSPQBackup.decrypt(record: record, algorithm: algorithm, network: network, password: password)
        defer { seed.resetBytes(in: 0..<seed.count) }
        return try restore(id: id, algorithm: algorithm, seed: seed)
    }
    public func delete(id: UUID, algorithm: TOSPQAlgorithm) throws {
        let status = SecItemDelete(query(id: id, algorithm: algorithm) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TOSPQError.keychain(status) }
    }
}
