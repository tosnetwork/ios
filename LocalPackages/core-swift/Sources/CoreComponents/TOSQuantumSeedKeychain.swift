import Foundation
import Security

/// Local role custody. Independent rescue custody requires keeping its record on the separate device.
/// Keychain presence does not authorize a transaction or establish a live chain route.
public final class TOSQuantumSeedKeychain {
    public enum MasterProfile { case nativeMnemonic, rawMaster32 }
    public struct Context {
        public let network: Data
        public let globalID: Int32
        public let account: UInt32
        public let generation: UInt32
        public init(network: Data, globalID: Int32, account: UInt32, generation: UInt32) throws {
            guard network.count == 32 else { throw TOSPQError.invalidInput }
            self.network = network; self.globalID = globalID; self.account = account; self.generation = generation
        }
    }
    private let lock = NSLock()
    public init() {}
    /// Initial binding only. Native mnemonic validation precedes this call;
    /// successful storage neither returns a signer nor approves current authority.
    public func restoreDerivedAndWipe(id: UUID, role: TOSQuantumRole, context: Context, master: inout Data,
                                     inputProfile: MasterProfile, declaredProfile: MasterProfile,
                                     expectedPublicKey: Data) throws -> Data {
        var seed = try Self.deriveBoundAndWipe(role: role, context: context, master: &master,
            inputProfile: inputProfile, declaredProfile: declaredProfile, expectedPublicKey: expectedPublicKey)
        defer { seed.resetBytes(in: 0..<seed.count) }
        return try importAndWipe(id: id, role: role, context: context, seed: &seed)
    }
    internal static func deriveBoundAndWipe(role: TOSQuantumRole, context: Context, master: inout Data,
                                           inputProfile: MasterProfile, declaredProfile: MasterProfile,
                                           expectedPublicKey: Data) throws -> Data {
        defer { master.resetBytes(in: 0..<master.count) }
        guard inputProfile == declaredProfile, expectedPublicKey.count == role.publicKeySize else { throw TOSPQError.keyBinding }
        var seed = try TOSQuantumKdf.deriveAndWipe(material: role == .primary ? .primary : .rescue,
            master: &master, network: context.network, globalID: context.globalID, account: context.account, generation: context.generation)
        do {
            guard try TOSQuantumSigner.publicKey(role: role, seed: seed) == expectedPublicKey else { throw TOSPQError.keyBinding }
            return seed
        } catch { seed.resetBytes(in: 0..<seed.count); throw error }
    }
    private func query(id: UUID, role: TOSQuantumRole) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "network.tos.wallet.quantum.seed.v1",
         kSecAttrAccount: "\(role.rawValue).\(id.uuidString)", kSecAttrSynchronizable: false]
    }
    internal static func header(id: UUID, role: TOSQuantumRole, context: Context) -> Data {
        var bytes = Data("TOSR2K01".utf8) + Data([UInt8(role.rawValue)])
        var uuid = id.uuid
        bytes.append(withUnsafeBytes(of: &uuid) { Data($0) }); bytes.append(context.network)
        for value in [UInt32(bitPattern: context.globalID), context.account, context.generation] {
            var big = value.bigEndian
            bytes.append(withUnsafeBytes(of: &big) { Data($0) })
        }
        return bytes
    }
    internal static func seed(record: Data, id: UUID, role: TOSQuantumRole, context: Context) throws -> Data {
        let expected = header(id: id, role: role, context: context)
        guard record.count == expected.count + role.seedSize, record.prefix(expected.count) == expected else {
            throw TOSPQError.keyBinding
        }
        return record.subdata(in: expected.count..<record.count)
    }
    public func importAndWipe(id: UUID, role: TOSQuantumRole, context: Context, seed: inout Data) throws -> Data {
        defer { seed.resetBytes(in: 0..<seed.count) }
        lock.lock(); defer { lock.unlock() }
        let publicKey = try TOSQuantumSigner.publicKey(role: role, seed: seed)
        var record = Self.header(id: id, role: role, context: context) + seed
        defer { record.resetBytes(in: 0..<record.count) }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .userPresence, &error) else { throw TOSPQError.invalidInput }
        var q = query(id: id, role: role)
        q[kSecAttrAccessControl] = access; q[kSecValueData] = record
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw TOSPQError.keychain(status) }
        return publicKey
    }
    private func withSeed<Result>(id: UUID, role: TOSQuantumRole, context: Context,
                                  body: (Data) throws -> Result) throws -> Result {
        lock.lock(); defer { lock.unlock() }
        var q = query(id: id, role: role); q[kSecReturnData] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        guard status == errSecSuccess, var record = value as? Data else { throw TOSPQError.keychain(status) }
        defer { record.resetBytes(in: 0..<record.count) }
        var seed = try Self.seed(record: record, id: id, role: role, context: context)
        defer { seed.resetBytes(in: 0..<seed.count) }
        return try body(seed)
    }
    /// Requires the same protected record access as signing; never returns seed material.
    public func publicKey(id: UUID, role: TOSQuantumRole, context: Context) throws -> Data {
        try withSeed(id: id, role: role, context: context) {
            try TOSQuantumSigner.publicKey(role: role, seed: $0)
        }
    }
    public func sign(id: UUID, role: TOSQuantumRole, context: Context, expectedPublicKey: Data,
                     purpose: TOSQuantumPurpose, digest: Data) throws -> Data {
        try withSeed(id: id, role: role, context: context) {
            try TOSQuantumSigner.sign(role: role, purpose: purpose, seed: $0,
                                  expectedPublicKey: expectedPublicKey, digest: digest)
        }
    }
    public func delete(id: UUID, role: TOSQuantumRole) throws {
        lock.lock(); defer { lock.unlock() }
        let status = SecItemDelete(query(id: id, role: role) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TOSPQError.keychain(status) }
    }
}
