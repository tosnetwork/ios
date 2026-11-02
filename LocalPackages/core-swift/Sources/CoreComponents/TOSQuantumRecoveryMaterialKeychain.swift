import Foundation
import Security

/// Whole validated recovery material, protected atomically. No public plaintext read API.
/// Uses the seed service so the existing explicit sign-out deleteAll also removes these records.
enum TOSQuantumRecoveryMaterialKeychain {
    private static func query(_ id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "network.tos.wallet.quantum.seed.v1",
         kSecAttrAccount: "recovery-material.\(id.uuidString)", kSecAttrSynchronizable: false]
    }
    static func withPayload<T>(id: UUID, birthHash: Data, encryptedDigest: Data,
                               body: (Data) throws -> T) throws -> T {
        var read = query(id); read[kSecReturnData] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &value)
        guard status == errSecSuccess, var record = value as? Data else { throw TOSPQError.keychain(status) }
        defer { record.resetBytes(in: 0..<record.count) }
        var plaintext = try payload(record, id: id, birthHash: birthHash, encryptedDigest: encryptedDigest)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        return try body(plaintext)
    }
    static func delete(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TOSPQError.keychain(status) }
    }
    static func encode(_ payload: Data, id: UUID, birthHash: Data, encryptedDigest: Data) throws -> Data {
        guard birthHash.count == 32, encryptedDigest.count == 32,
              (1...TOSQuantumBackupCipher.maximumPayload).contains(payload.count) else { throw TOSPQError.invalidInput }
        var uuid = id.uuid
        var length = UInt32(payload.count).bigEndian
        return Data("TOSQIM01".utf8) + withUnsafeBytes(of: &uuid) { Data($0) } + birthHash + encryptedDigest +
            withUnsafeBytes(of: &length) { Data($0) } + payload
    }

    static func payload(_ record: Data, id: UUID, birthHash: Data, encryptedDigest: Data) throws -> Data {
        guard (93...(92 + TOSQuantumBackupCipher.maximumPayload)).contains(record.count) else { throw TOSPQError.invalidInput }
        let bytes = Data(record)
        let length = bytes[88..<92].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length >= 1, length <= TOSQuantumBackupCipher.maximumPayload, bytes.count == 92 + Int(length) else {
            throw TOSPQError.invalidInput
        }
        let expected = try encode(Data(repeating: 0, count: 1), id: id, birthHash: birthHash, encryptedDigest: encryptedDigest)
        guard bytes.prefix(88) == expected.prefix(88) else { throw TOSPQError.keyBinding }
        return bytes.subdata(in: 92..<bytes.count)
    }

    static func store(_ payload: Data, id: UUID, birthHash: Data, encryptedDigest: Data) throws {
        var record = try encode(payload, id: id, birthHash: birthHash, encryptedDigest: encryptedDigest)
        defer { record.resetBytes(in: 0..<record.count) }
        let query = query(id)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence, &error) else { throw TOSPQError.invalidInput }
        var add = query
        add[kSecAttrAccessControl] = access
        add[kSecValueData] = record
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var read = query
            read[kSecReturnData] = true
            var value: CFTypeRef?
            let result = SecItemCopyMatching(read as CFDictionary, &value)
            guard result == errSecSuccess, var existing = value as? Data else { throw TOSPQError.keychain(result) }
            defer { existing.resetBytes(in: 0..<existing.count) }
            guard existing.count == record.count else { throw TOSPQError.keyBinding }
            var difference: UInt8 = 0
            for (a, b) in zip(existing, record) { difference |= a ^ b }
            guard difference == 0 else { throw TOSPQError.keyBinding }
        } else if status != errSecSuccess { throw TOSPQError.keychain(status) }
    }
}
