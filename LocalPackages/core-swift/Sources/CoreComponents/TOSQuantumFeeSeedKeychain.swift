import Foundation
import Security
import TOSPQNative

/// Protected fee seed only. Restore still uses the journal's next-slot barrier.
/// User authentication and enrollment/time/route proof acceptance are separate requirements.
public final class TOSQuantumFeeSeedKeychain {
    public struct Enrollment {
        public let context: TOSQuantumSeedKeychain.Context
        public let vault: Data
        public let tree: Data
        public let epoch: UInt32
        public let publicKey: Data
        public init(context: TOSQuantumSeedKeychain.Context, vault: Data, tree: Data, epoch: UInt32, publicKey: Data) throws {
            guard vault.count == 32, tree.count == 32, publicKey.count == 60 else { throw TOSPQError.invalidInput }
            self.context = context; self.vault = vault; self.tree = tree; self.epoch = epoch; self.publicKey = publicKey
        }
    }
    private let lock = NSLock()
    public init() {}
    private func query(id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "network.tos.wallet.quantum.fee.seed.v1",
         kSecAttrAccount: id.uuidString, kSecAttrSynchronizable: false]
    }
    internal static func header(id: UUID, enrollment: Enrollment) -> Data {
        var data = Data("TOSR2F01".utf8)
        var uuid = id.uuid
        data.append(withUnsafeBytes(of: &uuid) { Data($0) })
        data.append(enrollment.context.network); data.append(enrollment.vault); data.append(enrollment.tree)
        for value in [UInt32(bitPattern: enrollment.context.globalID), enrollment.context.account,
                      enrollment.context.generation, enrollment.epoch] {
            var big = value.bigEndian; data.append(withUnsafeBytes(of: &big) { Data($0) })
        }
        data.append(enrollment.publicKey)
        return data
    }
    internal static func bound(seed: Data, enrollment: Enrollment, leaf: UInt32, path: Data) -> Bool {
        guard seed.count == 48, path.count == 640, leaf < (1 << 20) else { return false }
        return seed.withUnsafeBytes { s in path.withUnsafeBytes { p in enrollment.publicKey.withUnsafeBytes { k in
            tos_wallet_lms_fee_bind_seed(s.bindMemory(to: UInt8.self).baseAddress, 48, leaf,
                p.bindMemory(to: UInt8.self).baseAddress, 640, k.bindMemory(to: UInt8.self).baseAddress, 60) == 1
        }}}
    }
    internal static func seed(record: Data, id: UUID, enrollment: Enrollment) throws -> Data {
        let expected = header(id: id, enrollment: enrollment)
        guard record.count == expected.count + 48, record.prefix(expected.count) == expected else { throw TOSPQError.keyBinding }
        return record.subdata(in: expected.count..<record.count)
    }
    public func importAndWipe(id: UUID, enrollment: Enrollment, seed: inout Data, leaf: UInt32, path: Data) throws {
        defer { seed.resetBytes(in: 0..<seed.count) }
        lock.lock(); defer { lock.unlock() }
        guard Self.bound(seed: seed, enrollment: enrollment, leaf: leaf, path: path) else { throw TOSPQError.keyBinding }
        var record = Self.header(id: id, enrollment: enrollment) + seed
        defer { record.resetBytes(in: 0..<record.count) }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .userPresence, &error) else { throw TOSPQError.invalidInput }
        var q = query(id: id); q[kSecAttrAccessControl] = access; q[kSecValueData] = record
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw TOSPQError.keychain(status) }
    }
    public func sign(id: UUID, enrollment: Enrollment, session: TOSQuantumFeeState, time: UInt32,
                     chainNext: UInt32, leaf: UInt32, digest: Data, path: Data) throws -> Data {
        guard session.matchesRoute(globalID: enrollment.context.globalID, network: enrollment.context.network,
                                   vault: enrollment.vault, tree: enrollment.tree, epoch: enrollment.epoch) else {
            throw TOSPQError.keyBinding
        }
        lock.lock(); defer { lock.unlock() }
        var q = query(id: id); q[kSecReturnData] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        guard status == errSecSuccess, var record = value as? Data else { throw TOSPQError.keychain(status) }
        defer { record.resetBytes(in: 0..<record.count) }
        var seed = try Self.seed(record: record, id: id, enrollment: enrollment)
        defer { seed.resetBytes(in: 0..<seed.count) }
        return try session.signOnceAndWipe(time: time, chainNext: chainNext, leaf: leaf, digest: digest,
                                          publicKey: enrollment.publicKey, seed: &seed, path: path)
    }
    public func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let status = SecItemDelete(query(id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TOSPQError.keychain(status) }
    }
}
