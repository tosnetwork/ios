import Foundation
import CoreComponents

/// The default creation path. Both roles currently share this device and recovery
/// phrase; this does not promise independent rescue custody or chain deployment.
internal final class TOSQuantumWalletCreation {
    typealias StoreRole = (UUID, TOSQuantumRole, TOSQuantumSeedKeychain.Context, inout Data) throws -> Data
    private let network: (UUID, TOSQuantumNetworkProfile) async throws -> TOSQuantumSelfPayNetwork
    private let storeRole: StoreRole
    private let saveRecord: (TOSQuantumCreationRecord) throws -> Void
    private let now: () -> Int64

    convenience init() {
        let keychain = TOSQuantumSeedKeychain()
        self.init(network: { id, profile in
            guard let endpoint = TOSRPCSettings.customEndpoint,
                  let url = URL(string: endpoint + "/jsonRPC") else { throw TOSQuantumNetworkProfile.Error.missingEndpoint }
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let relay = try TOSQuantumProofHTTPTransport(endpoint: url)
                        let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: profile.anchor())
                        let request = try TOSQuantumSelfPayNetwork.request(maximumAge: 300)
                        let proof = try session.enrollBound(request: request, now: Int64(Date().timeIntervalSince1970)) {
                            try relay.query($0, maximumBytes: $1)
                        }
                        continuation.resume(returning: try TOSQuantumSelfPayNetwork(proof: proof,
                            expectedGlobalID: profile.globalID, now: Int64(Date().timeIntervalSince1970), maximumAge: 300))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, storeRole: { try keychain.importAndWipe(id: $0, role: $1, context: $2, seed: &$3) },
        saveRecord: { try $0.save() }, now: { Int64(Date().timeIntervalSince1970) })
    }

    internal init(network: @escaping (UUID, TOSQuantumNetworkProfile) async throws -> TOSQuantumSelfPayNetwork,
                  storeRole: @escaping StoreRole, saveRecord: @escaping (TOSQuantumCreationRecord) throws -> Void,
                  now: @escaping () -> Int64) {
        self.network = network; self.storeRole = storeRole; self.saveRecord = saveRecord; self.now = now
    }

    /// Publish only after the recovery phrase and both protected role records are
    /// durable. The caller must propagate all persistence errors to the UI.
    func create(words: [String], profile: TOSQuantumNetworkProfile,
                saveMnemonic: (TOSQuantumCreationRecord) async throws -> Void,
                publish: (TOSQuantumCreationRecord) async throws -> Void) async throws {
        let id = UUID()
        let network = try await network(id, profile)
        guard network.globalID == profile.globalID else { throw TOSPQError.keyBinding }
        try Task.checkCancellation()
        var password = Data()
        var master = try TOSQuantumMnemonic.masterAndWipePassword(words: words, password: &password)
        defer { master.resetBytes(in: 0..<master.count) }
        var primaryMaster = master
        defer { primaryMaster.resetBytes(in: 0..<primaryMaster.count) }
        var primary = try TOSQuantumKdf.deriveAndWipe(material: .primary, master: &primaryMaster,
            network: network.namespace, globalID: network.globalID, account: 0, generation: 0)
        defer { primary.resetBytes(in: 0..<primary.count) }
        var rescue = try TOSQuantumKdf.deriveAndWipe(material: .rescue, master: &master,
            network: network.namespace, globalID: network.globalID, account: 0, generation: 0)
        defer { rescue.resetBytes(in: 0..<rescue.count) }
        let primaryKey = try TOSQuantumSigner.publicKey(role: .primary, seed: primary)
        let rescueKey = try TOSQuantumSigner.publicKey(role: .rescue, seed: rescue)
        let identity = try network.makeIdentity(primaryKey: primaryKey, rescueKey: rescueKey, now: now())
        let record = try TOSQuantumCreationRecord(id: id, profile: profile, identity: identity)
        let context = try TOSQuantumSeedKeychain.Context(network: network.namespace, globalID: network.globalID,
                                                       account: 0, generation: 0)
        try saveRecord(record)
        try await saveMnemonic(record)
        try Task.checkCancellation()
        guard try storeRole(id, .primary, context, &primary) == primaryKey,
              try storeRole(id, .rescue, context, &rescue) == rescueKey else { throw TOSPQError.keyBinding }
        // Authentication prompts and storage can outlive the proof freshness window.
        try network.requireFresh(now: now())
        try Task.checkCancellation()
        try await publish(record)
    }
}
