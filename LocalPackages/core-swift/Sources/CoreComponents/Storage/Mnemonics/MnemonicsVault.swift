import CryptoKit
import CryptoSwift
import Foundation
import TKKeychain
import TonSwift
import TweetNacl

public struct MnemonicsVault {
    private struct MnemonicItem: Codable {
        let identifier: String
        let mnemonic: String
    }

    public enum Error: Swift.Error {
        case mnemonicsCorrupted
        case noMnemonic
        case other(Swift.Error)
    }

    private let keychainVault: TKKeychainVault
    private let seedProvider: () -> String

    public init(
        keychainVault: TKKeychainVault,
        seedProvider: @escaping () -> String
    ) {
        self.keychainVault = keychainVault
        self.seedProvider = seedProvider
    }

    public func hasMnemonics() -> Bool {
        do {
            _ = try loadEncryptedMnemonics()
            return true
        } catch Error.noMnemonic {
            return false
        } catch {
            // A locked or corrupt vault must not be treated as a new installation.
            return true
        }
    }

    public func addMnemonic(
        _ mnemonic: Mnemonic,
        identifier: MnemonicIdentifier,
        password: String
    ) async throws {
        do {
            let encryptedMnemonics = try loadEncryptedMnemonics()
            var mnemonics = try await decryptMnemonics(encryptedMnemonics, password: password)
            mnemonics[identifier] = mnemonic
            let encryptedUpdatedMnemonics = try await encryptMnemonics(mnemonics, password: password)
            try saveEncryptedMnemonics(encryptedUpdatedMnemonics)
        } catch Error.noMnemonic {
            let mnemonics = [identifier: mnemonic]
            let encryptedMnemonics = try await encryptMnemonics(mnemonics, password: password)
            try saveEncryptedMnemonics(encryptedMnemonics)
        }
    }

    public func addMnemoncs(_ mnemonics: Mnemonics, password: String) async throws {
        do {
            let encryptedMnemonics = try loadEncryptedMnemonics()
            var decryptedMnemonics = try await decryptMnemonics(encryptedMnemonics, password: password)
            decryptedMnemonics.merge(mnemonics, uniquingKeysWith: { $1 })
            let encryptedUpdatedMnemonics = try await encryptMnemonics(decryptedMnemonics, password: password)
            try saveEncryptedMnemonics(encryptedUpdatedMnemonics)
        } catch Error.noMnemonic {
            let encryptedMnemonics = try await encryptMnemonics(mnemonics, password: password)
            try saveEncryptedMnemonics(encryptedMnemonics)
        }
    }

    public func getMnemonic(
        identifier: MnemonicIdentifier,
        password: String
    ) async throws -> Mnemonic {
        let encryptedMnemonics = try loadEncryptedMnemonics()
        let mnemonics = try await decryptMnemonics(encryptedMnemonics, password: password)
        guard let mnemonic = mnemonics[identifier] else {
            throw Error.noMnemonic
        }
        return mnemonic
    }

    public func deleteMnemonic(
        identifier: MnemonicIdentifier,
        password: String
    ) async throws {
        let encryptedMnemonics = try loadEncryptedMnemonics()
        var mnemonics = try await decryptMnemonics(encryptedMnemonics, password: password)
        mnemonics[identifier] = nil
        let encryptedUpdatedMnemonics = try await encryptMnemonics(mnemonics, password: password)
        try saveEncryptedMnemonics(encryptedUpdatedMnemonics)
    }

    public func deleteAll() async throws {
        // Include both the current device-only record and legacy chunks.
        for accessible in [TKKeychainAccessible.whenUnlockedThisDeviceOnly, .whenUnlocked] {
            do { try keychainVault.delete(getMnemonicsVaultQuery(accessible: accessible)) }
            catch TKKeychainError.noItem {}
        }
        do { try deletePassword() } catch TKKeychainError.noItem {}
    }

    public func changePassword(
        oldPassword: String,
        newPassword: String
    ) async throws {
        let encryptedMnemonics = try loadEncryptedMnemonics()
        let decryptedMnemonics = try await decryptMnemonics(encryptedMnemonics, password: oldPassword)
        let reencryptedMnemonics = try await encryptMnemonics(decryptedMnemonics, password: newPassword)
        try saveEncryptedMnemonics(reencryptedMnemonics)
    }

    public func validatePassword(_ password: String) async throws {
        let encryptedMnemonics = try loadEncryptedMnemonics()
        _ = try await decryptMnemonics(encryptedMnemonics, password: password)
    }

    public func importEncryptedMnemonics(_ encryptedMnemonics: EncryptedMnemonics) throws {
        try saveEncryptedMnemonics(encryptedMnemonics)
    }

    public func savePassword(_ password: String) throws {
        let query = getPasswordQuery()
        try keychainVault.set(password, query: query)
    }

    public func getPassword() throws -> String {
        let query = getPasswordQuery()
        return try keychainVault.get(query: query)
    }

    public func deletePassword() throws {
        let query = getPasswordQuery()
        try keychainVault.delete(query)
    }

    public func getMnemonics(password: String) async throws -> Mnemonics {
        let encryptedMnemonics = try loadEncryptedMnemonics()
        return try await decryptMnemonics(encryptedMnemonics, password: password)
    }
}

private extension MnemonicsVault {
    func getAtomicRecordQuery() -> TKKeychainQuery {
        TKKeychainQuery(item: .genericPassword(service: "\(String.mnemonicsVaultKey)_\(seedProvider())",
            account: "encrypted_record_v2"), accessGroup: nil, biometry: .none, accessible: .whenUnlockedThisDeviceOnly)
    }

    func getChunksCountQuery() -> TKKeychainQuery {
        let service = "\(String.mnemonicsVaultKey)_\(seedProvider())"
        return TKKeychainQuery(
            item: .genericPassword(service: service, account: .encryptedMnemonicsChunksCountKey),
            accessGroup: nil,
            biometry: .none,
            accessible: .whenUnlocked
        )
    }

    func getChunkQuery(index: Int) -> TKKeychainQuery {
        let service = "\(String.mnemonicsVaultKey)_\(seedProvider())"
        let key = "\(String.encryptedMnemonicsChunkKey)\(index)"
        return TKKeychainQuery(
            item: .genericPassword(service: service, account: key),
            accessGroup: nil,
            biometry: .none,
            accessible: .whenUnlocked
        )
    }

    func getMnemonicsVaultQuery(accessible: TKKeychainAccessible = .whenUnlockedThisDeviceOnly) -> TKKeychainQuery {
        let service = "\(String.mnemonicsVaultKey)_\(seedProvider())"
        return TKKeychainQuery(
            item: .genericPassword(service: service, account: nil),
            accessGroup: nil,
            biometry: .none,
            accessible: accessible
        )
    }

    func getPasswordQuery() -> TKKeychainQuery {
        let service = "\(String.passwordVaultKey)_\(seedProvider())"
        return TKKeychainQuery(
            item: .genericPassword(service: service, account: .passwordKey),
            accessGroup: nil,
            biometry: .any,
            accessible: .whenUnlockedThisDeviceOnly
        )
    }

    func decryptMnemonics(_ encryptedMnemonics: EncryptedMnemonics, password: String) async throws -> Mnemonics {
        let data = try await ScryptHashBox.decrypt(
            string: encryptedMnemonics.ct,
            salt: encryptedMnemonics.salt,
            N: encryptedMnemonics.N,
            r: encryptedMnemonics.r,
            p: encryptedMnemonics.p,
            password: password,
            dkLen: MnemonicsEncryptionParams.passwordKeyLength
        )

        let decrypted = try JSONDecoder().decode([String: MnemonicItem].self, from: data)
        return try decrypted.mapValues {
            try Mnemonic(mnemonicWords: $0.mnemonic.components(separatedBy: " "))
        }
    }

    func encryptMnemonics(_ mnemonics: Mnemonics, password: String) async throws -> EncryptedMnemonics {
        var toEncrypt = [String: MnemonicItem]()
        for item in mnemonics {
            toEncrypt[item.key] = MnemonicItem(
                identifier: item.key,
                mnemonic: item.value.mnemonicWords.joined(separator: " ")
            )
        }
        let data = try JSONEncoder().encode(toEncrypt)

        let salt = try SecureRandom.getRandomBytes(length: 32)
        let ct = try await ScryptHashBox.encrypt(
            data: data,
            salt: salt,
            N: MnemonicsEncryptionParams.N,
            r: MnemonicsEncryptionParams.r,
            p: MnemonicsEncryptionParams.p,
            password: password,
            dkLen: MnemonicsEncryptionParams.passwordKeyLength
        )

        return EncryptedMnemonics(
            kind: "encrypted-scrypt-tweetnacl",
            N: MnemonicsEncryptionParams.N,
            r: MnemonicsEncryptionParams.r,
            p: MnemonicsEncryptionParams.p,
            salt: salt.toHexString(),
            ct: ct
        )
    }

    func saveEncryptedMnemonics(_ encryptedMnemonics: EncryptedMnemonics) throws {
        let data = try JSONEncoder().encode(encryptedMnemonics)
        guard data.count <= 1_048_576 else { throw Error.mnemonicsCorrupted }
        // TKKeychainVaultImplementation uses one SecItemUpdate (or SecItemAdd).
        // A failed update cannot leave a mixture of old and new ciphertext chunks.
        try keychainVault.set(data, query: getAtomicRecordQuery())
    }

    func loadEncryptedMnemonics() throws -> EncryptedMnemonics {
        do {
            let data: Data = try keychainVault.get(query: getAtomicRecordQuery())
            guard data.count <= 1_048_576 else { throw Error.mnemonicsCorrupted }
            return try JSONDecoder().decode(EncryptedMnemonics.self, from: data)
        } catch TKKeychainError.noItem {
            // Only genuine absence permits reading the legacy representation.
            // Corruption or Keychain access errors must not roll back the vault.
        }
        let count: Int
        do {
            let countQuery = getChunksCountQuery()
            count = try keychainVault.get(query: countQuery)
        } catch TKKeychainError.noItem {
            throw Error.noMnemonic
        }

        guard (1...512).contains(count) else { throw Error.mnemonicsCorrupted }
        do {
            let encryptedMnemonicsData = try (0 ..< count)
                .map {
                    let query = getChunkQuery(index: $0)
                    let chunk: Data = try keychainVault.get(query: query)
                    guard (1...Int.chunksSize).contains(chunk.count) else { throw Error.mnemonicsCorrupted }
                    return chunk
                }
                .reduce(into: Data()) { $0 = $0 + $1 }
            return try JSONDecoder().decode(EncryptedMnemonics.self, from: encryptedMnemonicsData)
        } catch {
            throw Error.mnemonicsCorrupted
        }
    }
}

private extension String {
    static let mnemonicsVaultKey = "mnemonics_vault"
    static let passwordVaultKey = "password_vault"
    static let encryptedMnemonicsChunksCountKey = "encrypted_chunks_count"
    static let encryptedMnemonicsChunkKey = "encrypted_chunk"
    static let passwordKey = "biometry_passcode"
}

private extension Int {
    static let chunksSize = 2048
}
