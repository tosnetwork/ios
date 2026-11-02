import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Authenticated framing only. Plaintext still requires typed role/identity validation.
enum TOSQuantumBackupCipher {
    private static let magic = Data("TOSQBK01".utf8)
    static let maximumPayload = 262144

    private static func derive(_ password: String, salt: Data) throws -> Data {
        guard password.unicodeScalars.count >= 12, password.utf8.count <= 1024,
              !password.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw TOSPQError.invalidInput
        }
        var bytes = password.utf8.map { Int8(bitPattern: $0) }
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var key = [UInt8](repeating: 0, count: 32)
        defer { _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes, bytes.count,
            [UInt8](salt), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600000, &key, key.count)
        guard status == kCCSuccess else { throw TOSPQError.invalidInput }
        return Data(key)
    }

    static func encrypt(_ payload: Data, password: String) throws -> Data {
        guard (1...maximumPayload).contains(payload.count) else { throw TOSPQError.invalidInput }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw TOSPQError.invalidInput }
        let nonce = AES.GCM.Nonce()
        var length = UInt32(payload.count).bigEndian
        let header = magic + Data([1]) + salt + nonce.withUnsafeBytes { Data($0) } +
            withUnsafeBytes(of: &length) { Data($0) }
        var key = try derive(password, salt: salt)
        defer { key.resetBytes(in: 0..<key.count) }
        let sealed = try AES.GCM.seal(payload, using: SymmetricKey(data: key), nonce: nonce, authenticating: header)
        return header + sealed.ciphertext + sealed.tag
    }

    static func decrypt(_ record: Data, password: String) throws -> Data {
        guard (58...(41 + maximumPayload + 16)).contains(record.count) else { throw TOSPQError.invalidInput }
        let bytes = Data(record) // Normalize indices for sliced Data inputs.
        guard bytes.prefix(8) == magic, bytes[8] == 1 else { throw TOSPQError.invalidInput }
        let length = bytes[37..<41].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length >= 1, length <= maximumPayload, bytes.count == 41 + Int(length) + 16 else {
            throw TOSPQError.invalidInput
        }
        var key = try derive(password, salt: bytes.subdata(in: 9..<25))
        defer { key.resetBytes(in: 0..<key.count) }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: bytes.subdata(in: 25..<37)),
            ciphertext: bytes.subdata(in: 41..<(41 + Int(length))), tag: bytes.suffix(16))
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: bytes.prefix(41))
    }
}
