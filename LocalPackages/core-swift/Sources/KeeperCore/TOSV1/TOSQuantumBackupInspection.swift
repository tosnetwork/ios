import Foundation
import CoreComponents

/// Historical file validation only. A result cannot sign, publish, or clear recovery isolation.
struct TOSQuantumBackupInspection {
    let fields: TOSQuantumBackupIdentityFields
    let identity: TOSQuantumBackupFileIdentity
    let roles: [TOSQuantumBackupInspectionSession.Role]

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
