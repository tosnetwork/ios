import Foundation
import CryptoKit
import CommonCrypto

/// Portable v1 seed backup, binding algorithm, network and the public-key identity.
public enum TOSPQBackup {
    private static let magic = Data("TOSPQB01".utf8)
    private static func derive(password: String, salt: Data) throws -> Data {
        guard password.utf16.count >= 12 else { throw TOSPQError.invalidInput }
        var passwordBytes = password.utf8.map { Int8(bitPattern: $0) }
        defer { _ = passwordBytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var result = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, passwordBytes.count,
            [UInt8](salt), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600000, &result, result.count)
        guard status == kCCSuccess else { throw TOSPQError.invalidInput }
        return Data(result)
    }
    public static func encrypt(algorithm: TOSPQAlgorithm, network: Int32, publicKey: Data, seed: Data, password: String) throws -> Data {
        guard try TOSPQSigner.publicKey(algorithm: algorithm, seed: seed) == publicKey else { throw TOSPQError.keyBinding }
        let salt = try TOSPQSigner.randomSeed().prefix(16)
        var number = network.bigEndian
        let header = magic + Data([UInt8(algorithm.rawValue)]) + withUnsafeBytes(of: &number) { Data($0) } +
            Data(CryptoKit.SHA256.hash(data: publicKey)) + salt
        var derived = try derive(password: password, salt: salt)
        defer { derived.resetBytes(in: 0..<derived.count) }
        let sealed = try CryptoKit.AES.GCM.seal(seed, using: SymmetricKey(data: derived), authenticating: header)
        return header + sealed.nonce.withUnsafeBytes { Data($0) } + sealed.ciphertext + sealed.tag
    }
    public static func decrypt(record: Data, algorithm: TOSPQAlgorithm, network: Int32, password: String) throws -> Data {
        guard record.count == 121, record.prefix(8) == magic, record[8] == UInt8(algorithm.rawValue) else { throw TOSPQError.invalidInput }
        let expected = record[9..<13].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int32(bitPattern: expected) == network else { throw TOSPQError.keyBinding }
        var derived = try derive(password: password, salt: record.subdata(in: 45..<61))
        defer { derived.resetBytes(in: 0..<derived.count) }
        let box = try CryptoKit.AES.GCM.SealedBox(nonce: CryptoKit.AES.GCM.Nonce(data: record.subdata(in: 61..<73)),
            ciphertext: record.subdata(in: 73..<105), tag: record.subdata(in: 105..<121))
        var seed = try CryptoKit.AES.GCM.open(box, using: SymmetricKey(data: derived), authenticating: record.prefix(61))
        do {
            let key = try TOSPQSigner.publicKey(algorithm: algorithm, seed: seed)
            guard Data(CryptoKit.SHA256.hash(data: key)) == record.subdata(in: 13..<45) else { throw TOSPQError.keyBinding }
            return seed
        } catch { seed.resetBytes(in: 0..<seed.count); throw error }
    }
}
