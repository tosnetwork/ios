import Foundation

/// Owns decrypted secrets during inspection. No signing or storage capability is exposed.
public final class TOSQuantumBackupInspectionSession {
    public struct Role {
        public let role: TOSQuantumRole
        public let account: UInt32
        public let generation: UInt32
        public let sourceProfile: UInt8
    }
    public let identity: TOSQuantumBackupIdentityFields
    private var payload: TOSQuantumBackupPayload?
    private let lock = NSLock()

    public init(encrypted: Data, password: String) throws {
        var plaintext = try TOSQuantumBackupCipher.decrypt(encrypted, password: password)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let parsed = try TOSQuantumBackupPayload.parseUnverified(plaintext)
        do {
            identity = try parsed.identityFields()
            payload = parsed
        } catch {
            parsed.wipe()
            throw error
        }
    }

    /// Keys must come from the strictly decoded snapshot; does not authenticate current chain roles.
    public func validateSecrets(primary: Data, rescue: Data) throws -> [Role] {
        lock.lock(); defer { lock.unlock() }
        guard let payload else { throw TOSPQError.invalidInput }
        try payload.validateSnapshotKeys(primary: primary, rescue: rescue)
        try payload.validateProvenance()
        return try payload.roles.map { entry in
            guard let role = TOSQuantumRole(rawValue: Int32(entry.role)) else { throw TOSPQError.invalidInput }
            return Role(role: role, account: entry.account, generation: entry.generation, sourceProfile: entry.sourceProfile)
        }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        payload?.wipe()
        payload = nil
    }
    deinit { close() }
}
