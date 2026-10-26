import Foundation
import CoreComponents

/// Read-only observation through the original enrollment. A balance is neither
/// signing authority nor a spendable-amount or fee estimate.
internal final class TOSQuantumAccountReader {
    internal enum Error: Swift.Error { case busy }
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
        guard case .Quantum(let identity) = wallet.identity.kind, let id = UUID(uuidString: wallet.id) else {
            throw TOSPQError.keyBinding
        }
        try Task.checkCancellation()
        try permits.enter(id)
        defer { permits.leave(id) }
        let result: TOSQuantumSelfPayAccount.Snapshot = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try self.readStored(id: id, identity: identity)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return result
    }

    internal func readStored(id: UUID, identity: TOSQuantumSelfPayIdentity) throws -> TOSQuantumSelfPayAccount.Snapshot {
        let record = try TOSQuantumCreationRecord.load(id: id, baseDirectory: baseDirectory)
        guard record.id == id, record.identity == identity else { throw TOSPQError.keyBinding }
        return try readEnrolled(id: id, identity: identity, profile: record.profile)
    }

    internal func readEnrolled(id: UUID, identity: TOSQuantumSelfPayIdentity,
                               profile: TOSQuantumNetworkProfile) throws -> TOSQuantumSelfPayAccount.Snapshot {
        guard identity.wallet.initialAuthority.globalID == profile.globalID else { throw TOSPQError.keyBinding }
        let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: profile.anchor(), baseDirectory: baseDirectory)
        let relay = try transport()
        let request = try JSONSerialization.data(withJSONObject: ["mode": "live", "max_age_seconds": Self.maximumAge, "config_params": [19]])
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
        return try account.snapshot(now: now())
    }
}
