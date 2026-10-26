import Foundation
import CoreComponents

/// The default creation path. Both roles currently share this device and recovery
/// phrase; this does not promise independent rescue custody or chain deployment.
internal final class TOSQuantumWalletCreation {
    typealias StoreRole = (UUID, TOSQuantumRole, TOSQuantumSeedKeychain.Context, inout Data) throws -> Data
    private let network: (UUID, TOSQuantumNetworkProfile) async throws -> TOSQuantumSelfPayNetwork
    private let resumeNetwork: (UUID, TOSQuantumNetworkProfile) async throws -> TOSQuantumSelfPayNetwork
    private let storeRole: StoreRole
    private let saveRecord: (TOSQuantumCreationRecord) throws -> Void
    private let now: () -> Int64
    private let discardUnrecordedCheckpoint: (UUID) throws -> Void
    private let completeRecord: (TOSQuantumCreationRecord) throws -> Void

    convenience init() {
        let keychain = TOSQuantumSeedKeychain()
        self.init(network: { id, profile in try await Self.observe(id: id, profile: profile, resume: false) },
            storeRole: { try keychain.importMissingAndWipe(id: $0, role: $1, context: $2, seed: &$3) },
            saveRecord: { try $0.save() }, now: { Int64(Date().timeIntervalSince1970) },
            resumeNetwork: { id, profile in try await Self.observe(id: id, profile: profile, resume: true) },
            completeRecord: { try $0.markPublished() },
            discardUnrecordedCheckpoint: { try TOSQuantumProofSession.removeCheckpoint(walletID: $0) })
    }

    private static func observe(id: UUID, profile: TOSQuantumNetworkProfile, resume: Bool) async throws -> TOSQuantumSelfPayNetwork {
            guard let endpoint = TOSRPCSettings.customEndpoint,
                  let url = URL(string: endpoint + "/jsonRPC") else { throw TOSQuantumNetworkProfile.Error.missingEndpoint }
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let relay = try TOSQuantumProofHTTPTransport(endpoint: url)
                        let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: profile.anchor())
                        let request = try TOSQuantumSelfPayNetwork.request(maximumAge: 300)
                        let transport: TOSQuantumProofBridge.Transport = { try relay.query($0, maximumBytes: $1) }
                        let timestamp = Int64(Date().timeIntervalSince1970)
                        let proof = try resume
                            ? session.readBound(request: request, now: timestamp, transport: transport)
                            : session.enrollBound(request: request, now: timestamp, transport: transport)
                        continuation.resume(returning: try TOSQuantumSelfPayNetwork(proof: proof,
                            expectedGlobalID: profile.globalID, now: Int64(Date().timeIntervalSince1970), maximumAge: 300))
                    } catch { continuation.resume(throwing: error) }
                }
            }
    }

    internal init(network: @escaping (UUID, TOSQuantumNetworkProfile) async throws -> TOSQuantumSelfPayNetwork,
                  storeRole: @escaping StoreRole, saveRecord: @escaping (TOSQuantumCreationRecord) throws -> Void,
                  now: @escaping () -> Int64,
                  resumeNetwork: ((UUID, TOSQuantumNetworkProfile) async throws -> TOSQuantumSelfPayNetwork)? = nil,
                  completeRecord: @escaping (TOSQuantumCreationRecord) throws -> Void = { _ in },
                  discardUnrecordedCheckpoint: @escaping (UUID) throws -> Void = { _ in }) {
        self.network = network; self.resumeNetwork = resumeNetwork ?? network; self.storeRole = storeRole; self.saveRecord = saveRecord; self.now = now; self.completeRecord = completeRecord; self.discardUnrecordedCheckpoint = discardUnrecordedCheckpoint
    }

    /// Publish only after the recovery phrase and both protected role records are
    /// durable. The caller must propagate all persistence errors to the UI.
    func create(words: [String], profile: TOSQuantumNetworkProfile,
                saveMnemonic: (TOSQuantumCreationRecord) async throws -> Void,
                publish: (TOSQuantumCreationRecord) async throws -> Void) async throws {
        let id = UUID()
        var recorded = false
        defer {
            if !recorded {
                do { try discardUnrecordedCheckpoint(id) }
                catch { NSLog("Quantum unrecorded checkpoint cleanup deferred for %@", id.uuidString) }
            }
        }
        let network = try await network(id, profile)
        guard network.globalID == profile.globalID else { throw TOSPQError.keyBinding }
        try Task.checkCancellation()
        var (primary, rescue) = try Self.derive(words: words, namespace: network.namespace, globalID: network.globalID)
        defer { primary.resetBytes(in: 0..<primary.count); rescue.resetBytes(in: 0..<rescue.count) }
        let primaryKey = try TOSQuantumSigner.publicKey(role: .primary, seed: primary)
        let rescueKey = try TOSQuantumSigner.publicKey(role: .rescue, seed: rescue)
        let identity = try network.makeIdentity(primaryKey: primaryKey, rescueKey: rescueKey, now: now())
        let record = try TOSQuantumCreationRecord(id: id, profile: profile, identity: identity)
        let context = try TOSQuantumSeedKeychain.Context(network: network.namespace, globalID: network.globalID,
                                                       account: 0, generation: 0)
        try saveRecord(record)
        recorded = true
        try await saveMnemonic(record)
        try Task.checkCancellation()
        guard try storeRole(id, .primary, context, &primary) == primaryKey,
              try storeRole(id, .rescue, context, &rescue) == rescueKey else { throw TOSPQError.keyBinding }
        // Authentication prompts and storage can outlive the proof freshness window.
        try network.requireFresh(now: now())
        try Task.checkCancellation()
        try await publish(record)
        finish(record)
    }

    private static func derive(words: [String], namespace: Data, globalID: Int32) throws -> (Data, Data) {
        var password = Data()
        var master = try TOSQuantumMnemonic.masterAndWipePassword(words: words, password: &password)
        defer { master.resetBytes(in: 0..<master.count) }
        var primaryMaster = master
        defer { primaryMaster.resetBytes(in: 0..<primaryMaster.count) }
        var primary = try TOSQuantumKdf.deriveAndWipe(material: .primary, master: &primaryMaster,
            network: namespace, globalID: globalID, account: 0, generation: 0)
        do {
            let rescue = try TOSQuantumKdf.deriveAndWipe(material: .rescue, master: &master,
                network: namespace, globalID: globalID, account: 0, generation: 0)
            return (primary, rescue)
        } catch { primary.resetBytes(in: 0..<primary.count); throw error }
    }

    /// Resume only the retained birth identity. A new network selection cannot
    /// replace its anchor, UUID or keys, and existing custody is never overwritten.
    func resume(words: [String], record: TOSQuantumCreationRecord,
                publish: (TOSQuantumCreationRecord) async throws -> Void) async throws {
        let network = try await resumeNetwork(record.id, record.profile)
        let authority = record.identity.wallet.initialAuthority
        guard network.globalID == record.profile.globalID, network.globalID == authority.globalID,
              network.namespace == authority.namespace else { throw TOSPQError.keyBinding }
        try Task.checkCancellation()
        var (primary, rescue) = try Self.derive(words: words, namespace: authority.namespace, globalID: authority.globalID)
        defer { primary.resetBytes(in: 0..<primary.count); rescue.resetBytes(in: 0..<rescue.count) }
        guard try TOSQuantumSigner.publicKey(role: .primary, seed: primary) == authority.primaryKey,
              try TOSQuantumSigner.publicKey(role: .rescue, seed: rescue) == authority.rescueKey else { throw TOSPQError.keyBinding }
        let context = try TOSQuantumSeedKeychain.Context(network: authority.namespace, globalID: authority.globalID,
                                                       account: record.account, generation: record.generation)
        guard try storeRole(record.id, .primary, context, &primary) == authority.primaryKey,
              try storeRole(record.id, .rescue, context, &rescue) == authority.rescueKey else { throw TOSPQError.keyBinding }
        try network.requireFresh(now: now())
        try Task.checkCancellation()
        try await publish(record)
        finish(record)
    }
    private func finish(_ record: TOSQuantumCreationRecord) {
        do { try completeRecord(record) }
        catch { NSLog("Quantum enrollment journal close deferred for %@", record.id.uuidString) }
    }

}
