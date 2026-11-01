import Foundation
import CoreComponents
import TonSwift

/// Historical file validation only. A result cannot sign, publish, or clear recovery isolation.
struct TOSQuantumBackupInspection {
    enum Match: Equatable { case matchesCurrent, stale, unavailable }
    struct ObservedRole {
        let role: TOSQuantumRole
        let match: Match
    }
    let fields: TOSQuantumBackupIdentityFields
    let identity: TOSQuantumBackupFileIdentity
    let roles: [TOSQuantumBackupInspectionSession.Role]

    /// Only a fresh proof-bound observation may classify the file's individual declared roles.
    /// Matching keys do not approve an operation, retirement policy, or release recovery isolation.
    func classify(observation: TOSQuantumAccountReader.Observation, now: Int64) throws -> [ObservedRole] {
        try observation.requireFresh(now: now)
        guard observation.identity == identity.birth, observation.profile.globalID == fields.globalID,
              Data(hex: observation.profile.rootHash) == fields.rootHash,
              Data(hex: observation.profile.fileHash) == fields.fileHash else { throw TOSPQError.keyBinding }
        let current: TOSQuantumSelfPayAuthority?
        if case .active(let state) = observation.snapshot.status {
            guard state.authority.globalID == fields.globalID, state.authority.namespace == fields.namespace else {
                throw TOSPQError.keyBinding
            }
            current = state.authority
        } else { current = nil }
        let result = roles.map { ObservedRole(role: $0.role,
            match: Self.compare(role: $0.role, snapshot: identity.snapshot, current: current)) }
        try observation.requireFresh(now: now)
        return result
    }

    /// Pure comparison only. A caller cannot mint a fresh observation with this helper.
    static func compare(role: TOSQuantumRole, snapshot: TOSQuantumSelfPayAuthority,
                        current: TOSQuantumSelfPayAuthority?) -> Match {
        guard let current else { return .unavailable }
        let stored = role == .primary ? snapshot.primaryKey : snapshot.rescueKey
        let installed = role == .primary ? current.primaryKey : current.rescueKey
        return stored == installed ? .matchesCurrent : .stale
    }

    init(encrypted: Data, password: String, profile: TOSQuantumNetworkProfile,
         expectedNamespace: Data) throws {
        let session = try TOSQuantumBackupInspectionSession(encrypted: encrypted, password: password)
        defer { session.close() }
        let identity = try TOSQuantumBackupFileIdentity(fields: session.identity, profile: profile,
            expectedNamespace: expectedNamespace)
        roles = try session.validateSecrets(primary: identity.snapshot.primaryKey, rescue: identity.snapshot.rescueKey)
        self.identity = identity
        fields = session.identity
    }
}
