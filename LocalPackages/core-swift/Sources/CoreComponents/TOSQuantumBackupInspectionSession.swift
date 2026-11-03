import Foundation
import CryptoKit
import TonSwift

/// Owns decrypted secrets during inspection and narrow protected persistence. Never signs or returns secrets.
public final class TOSQuantumBackupInspectionSession {
    public struct Role {
        public let role: TOSQuantumRole
        public let account: UInt32
        public let generation: UInt32
        public let sourceProfile: UInt8
    }
    public let identity: TOSQuantumBackupIdentityFields
    public let encryptedDigest: Data
    private var payload: TOSQuantumBackupPayload?
    private var secretsValidated = false
    private let lock = NSLock()

    public init(encrypted: Data, password: String) throws {
        var plaintext = try TOSQuantumBackupCipher.decrypt(encrypted, password: password)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let parsed = try TOSQuantumBackupPayload.parseUnverified(plaintext)
        do {
            identity = try parsed.identityFields()
            encryptedDigest = Data(SHA256.hash(data: encrypted))
            payload = parsed
        } catch {
            parsed.wipe()
            throw error
        }
    }
    internal init(protectedPayload: Data, originalDigest: Data) throws {
        guard originalDigest.count == 32 else { throw TOSPQError.invalidInput }
        let parsed = try TOSQuantumBackupPayload.parseUnverified(protectedPayload)
        do {
            identity = try parsed.identityFields()
            encryptedDigest = originalDigest
            payload = parsed
        } catch { parsed.wipe(); throw error }
    }
    /// Requires the original user-presence-protected Keychain item, not the old file/password.
    public static func openProtected(id: UUID, birthHash: Data, originalDigest: Data) throws -> TOSQuantumBackupInspectionSession {
        guard birthHash.count == 32, originalDigest.count == 32 else { throw TOSPQError.invalidInput }
        return try TOSQuantumRecoveryMaterialKeychain.withPayload(id: id, birthHash: birthHash, encryptedDigest: originalDigest) {
            try TOSQuantumBackupInspectionSession(protectedPayload: $0, originalDigest: originalDigest)
        }
    }

    /// The service must strictly decode the supplied current authority and verify a fresh observation.
    /// Retains original birth/provenance; never adds an undeclared role or returns plaintext.
    public func encryptedExport(current: TOSQuantumBackupIdentityFields, primary: Data, rescue: Data,
                                selected: [TOSQuantumRole], password: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let payload, (1...2).contains(selected.count),
              Set(selected.map(\.rawValue)).count == selected.count,
              current.globalID == payload.globalID, current.rootHash == payload.rootHash,
              current.fileHash == payload.fileHash, current.namespace == payload.namespace,
              current.birthBOC == payload.birthBOC else { throw TOSPQError.keyBinding }
        let roles = payload.roles.filter { entry in selected.contains(where: { $0.rawValue == Int32(entry.role) }) }
        guard roles.count == selected.count else { throw TOSPQError.keyBinding }
        var plaintext = try TOSQuantumBackupPayload.encodeUnverified(globalID: payload.globalID,
            root: payload.rootHash, file: payload.fileHash, namespace: payload.namespace,
            birth: payload.birthBOC, authority: current.authorityBOC, roles: roles)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let bound = try TOSQuantumBackupPayload.parseUnverified(plaintext)
        defer { bound.wipe() }
        try bound.validateSnapshotKeys(primary: primary, rescue: rescue)
        try bound.validateProvenance()
        return try TOSQuantumBackupCipher.encrypt(plaintext, password: password)
    }

    /// Keys must come from the strictly decoded snapshot; does not authenticate current chain roles.
    public func validateSecrets(primary: Data, rescue: Data) throws -> [Role] {
        lock.lock(); defer { lock.unlock() }
        secretsValidated = false
        guard let payload else { throw TOSPQError.invalidInput }
        try payload.validateSnapshotKeys(primary: primary, rescue: rescue)
        try payload.validateProvenance()
        secretsValidated = true
        return try payload.roles.map { entry in
            guard let role = TOSQuantumRole(rawValue: Int32(entry.role)) else { throw TOSPQError.invalidInput }
            return Role(role: role, account: entry.account, generation: entry.generation, sourceProfile: entry.sourceProfile)
        }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        payload?.wipe()
        payload = nil
        secretsValidated = false
    }
    /// Narrow privacy use of validated original root material. Seed-only roles
    /// are unavailable; a rotated root is not substituted for the birth primary.
    public func privacyMaster(binding: TOSPrivacyMasterSession.Binding) throws -> TOSPrivacyMasterSession {
        guard !Thread.isMainThread else { throw TOSPrivacyNative.Failure.requiresWorker }
        lock.lock(); defer { lock.unlock() }
        guard let payload, secretsValidated else { throw TOSPrivacyMasterSession.Failure.materialUnavailable }
        let roots = try Cell.fromBoc(src: payload.birthBOC)
        guard payload.globalID == binding.globalID, payload.namespace == binding.namespace,
              roots.count == 1, roots[0].hash() == binding.birthHash else { throw TOSPrivacyMasterSession.Failure.binding }
        try payload.validateProvenance()
        for role in payload.roles where role.sourceProfile == 2 || role.sourceProfile == 3 {
            var master = Data()
            defer { master.resetBytes(in: 0..<master.count) }
            if role.sourceProfile == 2 {
                let words = role.wordIndices.map { TonSwift.Mnemonic.words[Int($0)] }
                var password = role.phrasePassword
                defer { password.resetBytes(in: 0..<password.count) }
                master = try TOSQuantumMnemonic.masterAndWipePassword(words: words, password: &password)
            } else { master = role.master }
            do { return try TOSPrivacyMasterSession.boundMasterAndWipe(&master, binding: binding) }
            catch TOSPrivacyMasterSession.Failure.materialUnavailable { continue }
        }
        throw TOSPrivacyMasterSession.Failure.materialUnavailable
    }
    /// Low-level custody primitive. The wallet service must first persist isolation and verify fresh roles.
    public func persistProtectedMaterial(id: UUID, birthHash: Data, primary: Data, rescue: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard let payload else { throw TOSPQError.invalidInput }
        try payload.validateSnapshotKeys(primary: primary, rescue: rescue)
        try payload.validateProvenance()
        var plaintext = try TOSQuantumBackupPayload.encodeUnverified(globalID: payload.globalID,
            root: payload.rootHash, file: payload.fileHash, namespace: payload.namespace,
            birth: payload.birthBOC, authority: payload.authorityBOC, roles: payload.roles)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        try TOSQuantumRecoveryMaterialKeychain.store(plaintext, id: id, birthHash: birthHash, encryptedDigest: encryptedDigest)
    }
    deinit { close() }
}
