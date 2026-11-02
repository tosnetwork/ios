import Foundation
import TonSwift
import CoreComponents

/// Structurally verified file identity. Snapshot is historical, never a fresh chain capability.
struct TOSQuantumBackupFileIdentity {
    let birth: TOSQuantumSelfPayIdentity
    let snapshot: TOSQuantumSelfPayAuthority

    /// Profile and namespace must originate outside the backup, from approved/verified network data.
    init(fields: TOSQuantumBackupIdentityFields, profile: TOSQuantumNetworkProfile,
         expectedNamespace: Data) throws {
        guard expectedNamespace.count == 32, fields.globalID == profile.globalID,
              fields.rootHash == Data(hex: profile.rootHash), fields.fileHash == Data(hex: profile.fileHash),
              fields.namespace == expectedNamespace else { throw TOSPQError.keyBinding }
        birth = try TOSQuantumSelfPayIdentity(boc: fields.birthBOC)
        try birth.requireNetwork(globalID: fields.globalID, namespace: fields.namespace)
        snapshot = try TOSQuantumSelfPayAuthority.parse(
            TOSRPCOrdinaryBOC.decode(fields.authorityBOC.base64EncodedString()))
        guard snapshot.globalID == fields.globalID, snapshot.namespace == fields.namespace else {
            throw TOSPQError.keyBinding
        }
    }
}
