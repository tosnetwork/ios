import Foundation
import CoreComponents
import BigInt
import TonSwift

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
    internal static let maximumAge: Int64 = 300

    convenience init(baseDirectory: URL? = nil) {
        self.init(baseDirectory: baseDirectory, transport: {
            guard let endpoint = TOSRPCSettings.quantumEndpoint,
                  let url = TOSRPCSettings.jsonRPCEndpoint(for: endpoint) else { throw TOSQuantumNetworkProfile.Error.missingEndpoint }
            let relay = try TOSQuantumProofHTTPTransport(endpoint: url)
            return { query, maximumBytes in
                do {
                    let response = try relay.query(query, maximumBytes: maximumBytes)
                    if TOSRPCConnectivity.setUnavailable(false) {
                        NotificationCenter.default.post(name: .tosRPCAvailable, object: nil)
                    }
                    return response
                } catch TOSQuantumProofHTTPTransport.Error.unavailable {
                    if TOSRPCConnectivity.setUnavailable(true) {
                        NotificationCenter.default.post(name: .tosRPCUnavailable, object: nil)
                    }
                    throw TOSQuantumProofHTTPTransport.Error.unavailable
                } catch TOSQuantumProofHTTPTransport.Error.rpcRejected {
                    if TOSRPCConnectivity.setUnavailable(false) {
                        NotificationCenter.default.post(name: .tosRPCAvailable, object: nil)
                    }
                    throw TOSQuantumProofHTTPTransport.Error.rpcRejected
                }
            }
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
        let outbox = try TOSQuantumOutbox(baseDirectory: baseDirectory?.appendingPathComponent("outbox"))
        if let recovery = try outbox.recoveryRecordIfPresent(identity, id: id) {
            return try observeEnrolled(id: id, identity: identity, profile: recovery.profile, configIndices: configIndices)
        }
        let record = try TOSQuantumCreationRecord.load(id: id, baseDirectory: baseDirectory)
        guard record.id == id, record.identity == identity else { throw TOSPQError.keyBinding }
        return try observeEnrolled(id: id, identity: identity, profile: record.profile, configIndices: configIndices)
    }

    /// Enroll this import's UUID without resetting any existing checkpoint on retry.
    internal func observeRecoveryImport(_ checkpoint: TOSQuantumOutbox.BackupImportCheckpoint,
                                       expectedNamespace: Data) throws -> Observation {
        let session = try TOSQuantumProofSession(walletID: checkpoint.id,
            locallyProvisionedAnchor: checkpoint.profile.anchor(), baseDirectory: baseDirectory)
        let request = try TOSQuantumSelfPayNetwork.request(maximumAge: Self.maximumAge)
        let relay = try transport()
        do { _ = try session.enrollBound(request: request, now: now(), transport: relay) }
        catch {
            // Native initialize refuses existing state; read resumes it and never deletes/restores it.
            _ = try session.readBound(request: request, now: now(), transport: relay)
        }
        let observation = try observeEnrolled(id: checkpoint.id, identity: checkpoint.identity,
            profile: checkpoint.profile, configIndices: [8, 19, 48])
        let namespace = try TOSQuantumSelfPayNetwork.recoveryNamespace(proof: observation.network,
            expectedGlobalID: checkpoint.profile.globalID, now: now())
        guard namespace == expectedNamespace else { throw TOSPQError.keyBinding }
        try observation.requireFresh(now: now())
        return observation
    }

    internal func readEnrolled(id: UUID, identity: TOSQuantumSelfPayIdentity,
                               profile: TOSQuantumNetworkProfile) throws -> TOSQuantumSelfPayAccount.Snapshot {
        try observeEnrolled(id: id, identity: identity, profile: profile).snapshot
    }

    internal func observeEnrolled(id: UUID, identity: TOSQuantumSelfPayIdentity,
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
    /// Raw index rows never establish ownership, code support or a balance.
    internal struct TokenObservation {
        let owner: Observation
        let master: Address
        let wallet: Address
        let masterState: TOSTokenMasterState
        let state: TOSTokenWalletState?
        fileprivate let masterProof: TOSQuantumProofBridge.BoundRead
        fileprivate let walletProof: TOSQuantumProofBridge.BoundRead
        var balance: BigUInt { state?.balance ?? 0 }

        func requireFresh(now: Int64) throws {
            try owner.requireFresh(now: now)
            for (proof, address) in [(masterProof, master), (walletProof, wallet)] {
                try proof.requireLive(now: now, maximumAge: TOSQuantumAccountReader.maximumAge)
                try owner.network.requireSameCheckpoint(proof)
                guard (-60...TOSQuantumAccountReader.maximumAge).contains(now - Int64(try proof.provenAccountTime(expectedAddress: address.toRaw()))) else {
                    throw TOSPQError.invalidInput
                }
            }
        }
    }

    /// Choose a locally supported code family from the owner/master-derived address.
    internal func observeToken(owner: Observation, master: Address, wallet: Address) throws -> TokenObservation {
        let family = try TOSTokenContractCodes.family(owner: owner.identity.address, master: master, wallet: wallet)
        let code = family.wallet
        let masterCode = family.master
        try owner.requireFresh(now: now())
        guard wallet == (try TOSTokenWalletState.address(owner: owner.identity.address, master: master, walletCode: code)) else {
            throw TOSPQError.keyBinding
        }
        let session = try TOSQuantumProofSession(walletID: owner.id, locallyProvisionedAnchor: owner.profile.anchor(), baseDirectory: baseDirectory)
        let relay = try transport()
        func read(_ address: Address) throws -> TOSQuantumProofBridge.BoundRead {
            let request = try owner.network.requestAtCheckpoint(account: address.toRaw(), maximumAge: Self.maximumAge)
            let proof = try session.readBound(request: request, now: now(), transport: relay)
            try owner.network.requireSameCheckpoint(proof)
            try proof.requireLive(now: now(), maximumAge: Self.maximumAge)
            return proof
        }
        let masterProof = try read(master)
        let masterBytes = try masterProof.accountState(expectedAddress: master.toRaw(), expectedCodeHash: masterCode.hash())
        let masterData = try TOSQuantumAccountState.data(masterBytes, expectedAddress: master, expectedCode: masterCode)
        let masterState = try TOSTokenMasterState.decode(masterData, expectedWalletCode: code)
        let walletProof = try read(wallet)
        let state: TOSTokenWalletState?
        if try walletProof.provenAccountState(expectedAddress: wallet.toRaw()) == nil { state = nil }
        else {
            let bytes = try walletProof.accountState(expectedAddress: wallet.toRaw(), expectedCodeHash: code.hash())
            let data = try TOSQuantumAccountState.data(bytes, expectedAddress: wallet, expectedCode: code)
            state = try TOSTokenWalletState.decode(data, wallet: wallet, owner: owner.identity.address, master: master, walletCode: code)
        }
        let result = TokenObservation(owner: owner, master: master, wallet: wallet, masterState: masterState,
                                      state: state, masterProof: masterProof, walletProof: walletProof)
        try result.requireFresh(now: now())
        return result
    }

}
