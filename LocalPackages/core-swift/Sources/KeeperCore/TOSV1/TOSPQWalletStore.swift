import Foundation
import CoreComponents

public struct TOSPQWalletRecord: Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let algorithm: TOSPQAlgorithm
    public let network: Int32
    public let publicKey: Data
    public func descriptor() throws -> TOSPQWallet {
        try TOSPQWallet(algorithm: algorithm, publicKey: publicKey, network: network)
    }
}

/// Registry contains public metadata only. PQ seeds stay in device-only Keychain records.
/// Actor isolation prevents simultaneous create/import/delete from replacing an identity.
public actor TOSPQWalletStore {
    public static let shared = TOSPQWalletStore()
    private let defaults: UserDefaults
    private let keychain = TOSPQSeedKeychain()
    private let registry = "network.tos.wallet.pq.registry.v1"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func list() throws -> [TOSPQWalletRecord] {
        guard let data = defaults.data(forKey: registry) else { return [] }
        let records = try JSONDecoder().decode([TOSPQWalletRecord].self, from: data)
        guard Set(records.map(\.id)).count == records.count else { throw TOSPQError.keyBinding }
        for record in records { _ = try record.descriptor() }
        return records
    }
    private func save(_ records: [TOSPQWalletRecord]) throws {
        defaults.set(try JSONEncoder().encode(records), forKey: registry)
    }
    public func create(name: String, algorithm: TOSPQAlgorithm, network: Int32) throws -> TOSPQWalletRecord {
        var records = try list()
        guard !name.isEmpty, name.utf8.count <= 128 else { throw TOSPQError.invalidInput }
        let id = UUID()
        let key = try keychain.create(id: id, algorithm: algorithm)
        let record = TOSPQWalletRecord(id: id, name: name, algorithm: algorithm, network: network, publicKey: key)
        do { records.append(record); try save(records); return record }
        catch { try? keychain.delete(id: id, algorithm: algorithm); throw error }
    }
    private func existing(_ id: UUID) throws -> TOSPQWalletRecord {
        guard let record = try list().first(where: { $0.id == id }) else { throw TOSPQError.keyBinding }
        return record
    }
    public func sign(id: UUID, message: Data) throws -> Data {
        let record = try existing(id)
        return try keychain.sign(id: id, algorithm: record.algorithm, expectedPublicKey: record.publicKey, message: message)
    }
    public func backup(id: UUID, password: String) throws -> Data {
        let record = try existing(id)
        return try keychain.backup(id: id, algorithm: record.algorithm, network: record.network,
                                  expectedPublicKey: record.publicKey, password: password)
    }
    public func restore(name: String, algorithm: TOSPQAlgorithm, network: Int32, backup: Data, password: String) throws -> TOSPQWalletRecord {
        var records = try list()
        guard !name.isEmpty, name.utf8.count <= 128 else { throw TOSPQError.invalidInput }
        let id = UUID()
        let key = try keychain.restoreBackup(id: id, algorithm: algorithm, network: network, record: backup, password: password)
        guard !records.contains(where: { $0.algorithm == algorithm && $0.network == network && $0.publicKey == key }) else {
            try keychain.delete(id: id, algorithm: algorithm); throw TOSPQError.keyBinding
        }
        let record = TOSPQWalletRecord(id: id, name: name, algorithm: algorithm, network: network, publicKey: key)
        do { records.append(record); try save(records); return record }
        catch { try? keychain.delete(id: id, algorithm: algorithm); throw error }
    }
    public func delete(id: UUID) throws {
        let record = try existing(id)
        try keychain.delete(id: id, algorithm: record.algorithm)
        try save(list().filter { $0.id != id })
    }
}
