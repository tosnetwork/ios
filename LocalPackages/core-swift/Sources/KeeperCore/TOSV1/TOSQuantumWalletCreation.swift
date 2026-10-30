import Foundation
import CoreComponents

public enum TOSQuantumWalletCreationError: LocalizedError {
    case pendingPhraseIdentityMismatch

    public var errorDescription: String? {
        switch self {
        case .pendingPhraseIdentityMismatch:
            return "The saved recovery phrase does not match this unfinished wallet."
        }
    }
}

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
            guard let endpoint = TOSRPCSettings.quantumEndpoint,
                  let url = TOSRPCSettings.jsonRPCEndpoint(for: endpoint) else { throw TOSQuantumNetworkProfile.Error.missingEndpoint }
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

    /// Verify the configured node against the locally selected trust anchor
    /// before showing a new recovery phrase. This creates no wallet or keys;
    /// the actual creation repeats the fresh proof after backup confirmation.
    static func preflight(profile: TOSQuantumNetworkProfile) async throws {
        let id = UUID()
        do {
            _ = try await observe(id: id, profile: profile, resume: false)
        } catch {
            let failure = error
            do { try TOSQuantumProofSession.removeCheckpoint(walletID: id) }
            catch { NSLog("Quantum preflight checkpoint cleanup deferred for %@", id.uuidString) }
            throw failure
        }
        try TOSQuantumProofSession.removeCheckpoint(walletID: id)
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

    /// Restore a native phrase against the selected local trust profile. The
    /// authenticated observation and deterministic identity derivation happen
    /// before any journal, mnemonic, or keychain write. Existing identities
    /// are checked in place and never rebound to a newly generated UUID.
    func restore(words: [String], profile: TOSQuantumNetworkProfile,
                 existing: (TOSQuantumSelfPayIdentity) throws -> TOSQuantumCreationRecord?,
                 confirmExisting: (TOSQuantumCreationRecord) async throws -> Void,
                 saveMnemonic: (TOSQuantumCreationRecord) async throws -> Void,
                 cleanupMnemonic: (TOSQuantumCreationRecord) async throws -> Void,
                 publish: (TOSQuantumCreationRecord) async throws -> Void) async throws {
        let candidateID = UUID()
        let observed: TOSQuantumSelfPayNetwork
        do { observed = try await network(candidateID, profile) }
        catch {
            try discardUnrecordedCheckpoint(candidateID)
            throw error
        }
        // The probe identity is only for the authenticated observation. Remove
        // its session checkpoint before proceeding to any durable wallet data.
        try discardUnrecordedCheckpoint(candidateID)
        guard observed.globalID == profile.globalID else { throw TOSPQError.keyBinding }
        try Task.checkCancellation()
        var (primary, rescue) = try Self.derive(words: words, namespace: observed.namespace, globalID: observed.globalID)
        defer { primary.resetBytes(in: 0..<primary.count); rescue.resetBytes(in: 0..<rescue.count) }
        let primaryKey = try TOSQuantumSigner.publicKey(role: .primary, seed: primary)
        let rescueKey = try TOSQuantumSigner.publicKey(role: .rescue, seed: rescue)
        let identity = try observed.makeIdentity(primaryKey: primaryKey, rescueKey: rescueKey, now: now())
        if let prior = try existing(identity) {
            guard prior.profile == profile, prior.identity == identity else { throw TOSPQError.keyBinding }
            let bound = try await resumeNetwork(prior.id, prior.profile)
            let authority = prior.identity.wallet.initialAuthority
            guard bound.globalID == profile.globalID, bound.namespace == authority.namespace,
                  authority.globalID == profile.globalID else { throw TOSPQError.keyBinding }
            try bound.requireFresh(now: now())
            try await confirmExisting(prior)
            let context = try TOSQuantumSeedKeychain.Context(network: authority.namespace, globalID: authority.globalID,
                                                              account: prior.account, generation: prior.generation)
            try TOSQuantumSeedKeychain().importMissingRolesAndWipe(id: prior.id, context: context,
                primarySeed: &primary, rescueSeed: &rescue,
                expectedPrimaryKey: primaryKey, expectedRescueKey: rescueKey)
            try bound.requireFresh(now: now())
            try await publish(prior)
            return
        }
        let record = try TOSQuantumCreationRecord(id: candidateID, profile: profile, identity: identity)
        let context = try TOSQuantumSeedKeychain.Context(network: observed.namespace, globalID: observed.globalID,
                                                          account: 0, generation: 0)
        var mnemonicAttempted = false
        do {
            // The discovery checkpoint was discarded before checking existing
            // wallets. A newly restored wallet needs its own durable enrollment
            // before publishing readers that require an initialized checkpoint.
            let enrolled = try await network(candidateID, profile)
            guard enrolled.globalID == observed.globalID, enrolled.namespace == observed.namespace else {
                throw TOSPQError.keyBinding
            }
            try enrolled.requireFresh(now: now())
            try saveRecord(record)
            // Treat a throwing save as potentially partially durable and
            // attempt removal for this newly allocated UUID as well.
            mnemonicAttempted = true
            try await saveMnemonic(record)
            try Task.checkCancellation()
            guard try storeRole(candidateID, .primary, context, &primary) == primaryKey else { throw TOSPQError.keyBinding }
            guard try storeRole(candidateID, .rescue, context, &rescue) == rescueKey else { throw TOSPQError.keyBinding }
            try observed.requireFresh(now: now())
            try Task.checkCancellation()
            try await publish(record)
            finish(record)
        } catch {
            var cleanupError: Swift.Error?
            do { try TOSQuantumSeedKeychain().delete(id: candidateID, role: .rescue) }
            catch { cleanupError = error }
            do { try TOSQuantumSeedKeychain().delete(id: candidateID, role: .primary) }
            catch { cleanupError = cleanupError ?? error }
            if mnemonicAttempted {
                do { try await cleanupMnemonic(record) }
                catch { cleanupError = cleanupError ?? error }
            }
            do { try TOSQuantumCreationRecord.remove(id: candidateID) }
            catch { cleanupError = cleanupError ?? error }
            do { try discardUnrecordedCheckpoint(candidateID) }
            catch { cleanupError = cleanupError ?? error }
            throw cleanupError ?? error
        }
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

    /// Check the locally retained phrase against the immutable pending identity
    /// before displaying it as the backup for that wallet. This is offline; the
    /// fresh network proof remains mandatory when the enrollment is resumed.
    static func requireMnemonicMatches(words: [String], record: TOSQuantumCreationRecord) throws {
        let words = TOSV1MnemonicValidator.normalize(words)
        guard TOSMnemonic.isValid(words) else { throw Mnemonic.Error.incorrectMnemonicWords }
        let authority = record.identity.wallet.initialAuthority
        guard authority.globalID == record.profile.globalID else { throw TOSPQError.keyBinding }
        var (primary, rescue) = try derive(words: words, namespace: authority.namespace,
                                           globalID: authority.globalID)
        defer { primary.resetBytes(in: 0..<primary.count); rescue.resetBytes(in: 0..<rescue.count) }
        guard try TOSQuantumSigner.publicKey(role: .primary, seed: primary) == authority.primaryKey,
              try TOSQuantumSigner.publicKey(role: .rescue, seed: rescue) == authority.rescueKey else {
            throw TOSQuantumWalletCreationError.pendingPhraseIdentityMismatch
        }
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
