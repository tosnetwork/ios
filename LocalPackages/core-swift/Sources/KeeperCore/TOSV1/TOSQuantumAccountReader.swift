import Foundation
import CoreComponents

/// Read-only observation through the original enrollment. A balance is neither
/// signing authority nor a spendable-amount or fee estimate.
internal final class TOSQuantumAccountReader {
    internal enum Error: Swift.Error { case busy }
    /// The proof, not a decoded balance or RPC getter, is the authority for
    /// subsequent transaction preparation and receipt/history anchoring.
    internal struct Observation {
        let id: UUID
        let identity: TOSQuantumSelfPayIdentity
        let profile: TOSQuantumNetworkProfile
        let network: TOSQuantumProofBridge.BoundRead
        let proof: TOSQuantumProofBridge.BoundRead
        let snapshot: TOSQuantumSelfPayAccount.Snapshot
        private let account: TOSQuantumSelfPayAccount

        fileprivate init(id: UUID, identity: TOSQuantumSelfPayIdentity, profile: TOSQuantumNetworkProfile,
                         network: TOSQuantumProofBridge.BoundRead, proof: TOSQuantumProofBridge.BoundRead,
                         account: TOSQuantumSelfPayAccount, now: Int64) throws {
            self.id = id; self.identity = identity; self.profile = profile
            self.network = network; self.proof = proof; self.account = account
            snapshot = try account.snapshot(now: now)
        }
        func requireFresh(now: Int64) throws {
            try network.requireLive(now: now, maximumAge: TOSQuantumAccountReader.maximumAge)
            _ = try account.snapshot(now: now)
        }
    }
    internal final class Permits {
        private let lock = NSLock()
        private var active = Set<UUID>()
        func enter(_ id: UUID) throws {
            try lock.withLock {
                guard active.count < 2, !active.contains(id) else { throw Error.busy }
                active.insert(id)
            }
        }
        func leave(_ id: UUID) { lock.withLock { _ = active.remove(id) } }
    }
    private static let sharedPermits = Permits()
    private let permits: Permits
    private let baseDirectory: URL?
    private let transport: () throws -> TOSQuantumProofBridge.Transport
    private let now: () -> Int64
    private static let maximumAge: Int64 = 300

    convenience init() {
        self.init(transport: {
            guard let endpoint = TOSRPCSettings.customEndpoint,
                  let url = URL(string: endpoint + "/jsonRPC") else { throw TOSQuantumNetworkProfile.Error.missingEndpoint }
            let relay = try TOSQuantumProofHTTPTransport(endpoint: url)
            return { try relay.query($0, maximumBytes: $1) }
        })
    }
    internal init(baseDirectory: URL? = nil,
                  transport: @escaping () throws -> TOSQuantumProofBridge.Transport,
                  now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }, permits: Permits? = nil) {
        self.baseDirectory = baseDirectory; self.transport = transport; self.now = now
        self.permits = permits ?? Self.sharedPermits
    }

    func read(wallet: Wallet) async throws -> TOSQuantumSelfPayAccount.Snapshot {
        try await observe(wallet: wallet).snapshot
    }

    func observe(wallet: Wallet, configIndices: [Int] = [19]) async throws -> Observation {
        guard case .Quantum(let identity) = wallet.identity.kind, let id = UUID(uuidString: wallet.id) else {
            throw TOSPQError.keyBinding
        }
        try Task.checkCancellation()
        try permits.enter(id)
        defer { permits.leave(id) }
        let result: Observation = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try self.observeStored(id: id, identity: identity, configIndices: configIndices)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return result
    }

    internal func readStored(id: UUID, identity: TOSQuantumSelfPayIdentity) throws -> TOSQuantumSelfPayAccount.Snapshot {
        try observeStored(id: id, identity: identity).snapshot
    }

    private func observeStored(id: UUID, identity: TOSQuantumSelfPayIdentity, configIndices: [Int] = [19]) throws -> Observation {
        let record = try TOSQuantumCreationRecord.load(id: id, baseDirectory: baseDirectory)
        guard record.id == id, record.identity == identity else { throw TOSPQError.keyBinding }
        return try observeEnrolled(id: id, identity: identity, profile: record.profile, configIndices: configIndices)
    }

    internal func readEnrolled(id: UUID, identity: TOSQuantumSelfPayIdentity,
                               profile: TOSQuantumNetworkProfile) throws -> TOSQuantumSelfPayAccount.Snapshot {
        try observeEnrolled(id: id, identity: identity, profile: profile).snapshot
    }

    private func observeEnrolled(id: UUID, identity: TOSQuantumSelfPayIdentity,
                                profile: TOSQuantumNetworkProfile, configIndices: [Int] = [19]) throws -> Observation {
        let allowed = Set([8, 18, 19, 20, 21, 24, 25, 48])
        guard !configIndices.isEmpty, configIndices.count <= allowed.count, configIndices.contains(19),
              Set(configIndices).count == configIndices.count, configIndices.allSatisfy(allowed.contains) else {
            throw TOSPQError.invalidInput
        }
        guard identity.wallet.initialAuthority.globalID == profile.globalID else { throw TOSPQError.keyBinding }
        let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: profile.anchor(), baseDirectory: baseDirectory)
        let relay = try transport()
        let request = try JSONSerialization.data(withJSONObject: ["mode": "live", "max_age_seconds": Self.maximumAge, "config_params": configIndices])
        let network = try session.readBound(request: request, now: now(), transport: relay)
        let config = try TOSRPCOrdinaryBOC.decode(network.provenConfigParam(19).base64EncodedString()).beginParse()
        guard try config.loadInt(bits: 32) == Int64(profile.globalID) else { throw TOSPQError.keyBinding }
        try config.endParse()
        let address = "0:" + identity.address.hash.map { String(format: "%02x", $0) }.joined()
        let accountRequest = try network.requestAtCheckpoint(account: address, maximumAge: Self.maximumAge)
        let proof = try session.readBound(request: accountRequest, now: now(), transport: relay)
        try network.requireSameCheckpoint(proof)
        let account = try TOSQuantumSelfPayAccount(identity: identity, proof: proof, now: now(), maximumAge: Self.maximumAge)
        try network.requireLive(now: now(), maximumAge: Self.maximumAge)
        return try Observation(id: id, identity: identity, profile: profile, network: network,
                               proof: proof, account: account, now: now())
    }
}
