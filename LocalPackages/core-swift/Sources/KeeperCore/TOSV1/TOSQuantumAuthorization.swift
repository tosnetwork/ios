import Foundation
import CryptoKit
import TonSwift
import CoreComponents

/// Strict original-request codec. A valid encoding is not chain evidence.
internal struct TOSQuantumStoredRequest {
    let deadline: UInt32
    let authorityHash: Data
    let epoch: UInt64
    let nonce: UInt64
    let kind: UInt8

    init(entry: TOSQuantumOutbox.Entry) throws {
        guard !entry.requestBOC.isEmpty, entry.requestBOC.count <= 1024 * 1024,
              entry.profile.globalID == entry.identity.wallet.initialAuthority.globalID else { throw TOSPQError.keyBinding }
        let cell = try TOSRPCOrdinaryBOC.decode(entry.requestBOC.base64EncodedString())
        guard cell.hash() == entry.requestHash else { throw TOSPQError.keyBinding }
        try TOSQuantumSelfPayAuthority.ordinary(cell)
        let s = try cell.beginParse()
        guard s.remainingBits == 1019, s.remainingRefs == 1,
              try s.loadUint(bits: 32) == 0x51535031,
              try s.loadInt(bits: 32) == Int64(entry.profile.globalID),
              try s.loadBytes(32) == entry.identity.wallet.initialAuthority.namespace else { throw TOSPQError.keyBinding }
        let address: Address = try s.loadType()
        guard address == entry.identity.address else { throw TOSPQError.keyBinding }
        authorityHash = try s.loadBytes(32)
        guard try s.loadUint(bits: 8) == UInt64(entry.role.rawValue) else { throw TOSPQError.keyBinding }
        epoch = try s.loadUint(bits: 64); nonce = try s.loadUint(bits: 64)
        deadline = UInt32(try s.loadUint(bits: 32)); kind = UInt8(try s.loadUint(bits: 8))
        let payload = try s.loadRef(); try s.endParse()
        try TOSQuantumSelfPayAuthority.ordinary(payload)
        let body = try payload.beginParse()
        guard deadline > 0, entry.role != .primary || kind == 0,
              (kind == 0 ? nonce < UInt64.max : epoch < UInt64.max) else { throw TOSPQError.keyBinding }
        switch kind {
        case 0:
            guard try body.loadUint(bits: 32) == 0x45584543 else { throw TOSPQError.keyBinding }
            let actions = try body.loadRef(); try body.endParse()
            try TOSQuantumAuth.validateActions(actions)
        case 1:
            guard entry.role == .rescue, try body.loadUint(bits: 32) == 0x434f4e46,
                  try body.loadUint(bits: 2) == 2 else { throw TOSPQError.keyBinding }
            try body.endParse()
        case 3:
            guard entry.role == .rescue, try body.loadUint(bits: 32) == 0x4c4f434b,
                  try body.loadUint(bits: 8) == 1 else { throw TOSPQError.keyBinding }
            try body.endParse()
        case 4:
            guard entry.role == .rescue, try body.loadUint(bits: 32) == 0x4d494752 else { throw TOSPQError.keyBinding }
            let successor = try TOSQuantumSelfPayAuthority.parse(body.loadRef()); try body.endParse()
            guard successor.globalID == entry.profile.globalID,
                  successor.namespace == entry.identity.wallet.initialAuthority.namespace else { throw TOSPQError.keyBinding }
        default: throw TOSPQError.keyBinding
        }
        try entry.paymentIntent?.requireBound(request: cell, role: entry.role)
    }
}

/// Includes the exact phase, signature and optional BOC. In particular, `signing`
/// with no persisted signature is different from a later signed authorization.
internal struct TOSQuantumAuthorizationBinding: Equatable {
    private let digest: Data
    internal var fingerprint: Data { digest }
    private struct OptionalBytes: Encodable {
        let present: Bool
        let bytes: Data?
        init(_ bytes: Data?) { present = bytes != nil; self.bytes = bytes }
    }
    private struct Intent: Encodable {
        let present: Bool
        let recipient: String?
        let amount: String?
        let bounce: Bool?
        let comment: OptionalBytes
        init(_ intent: TOSQuantumPaymentIntent?) {
            present = intent != nil; recipient = intent?.recipient.toRaw()
            amount = intent.map { String($0.amount) }; bounce = intent?.bounce
            comment = OptionalBytes(intent?.comment.map { Data($0.utf8) })
        }
    }
    private struct Material: Encodable {
        let domain: String
        let storageVersion: UInt8
        let birthHash: Data
        let globalID: Int32
        let rootHash: String
        let fileHash: String
        let operation: String
        let role: Int32
        let requestBytes: Data
        let requestHash: Data
        let deadline: UInt32
        let authorityHash: Data
        let epoch: UInt64
        let nonce: UInt64
        let actionKind: UInt8
        let signingPublicKey: Data
        let deploy: Bool
        let phase: String
        let signature: OptionalBytes
        let signedBOC: OptionalBytes
        let intent: Intent
        let approvalPresent: Bool
        let approval: TOSQuantumPaymentQuote.Approval?
    }
    init(_ entry: TOSQuantumOutbox.Entry) throws {
        let request = try TOSQuantumStoredRequest(entry: entry)
        guard entry.signingPublicKey.count == entry.role.publicKeySize,
              (entry.signature?.count ?? 0) <= entry.role.signatureSize,
              (entry.signedBOC?.count ?? 0) <= 1024 * 1024 else { throw TOSPQError.invalidInput }
        // Identity.encode serializes its cell DAG through a Set-based SDK BOC
        // order. Bind the stable birth cell hash, never that reserialization.
        // Stored request/message bytes remain exact, even for equal cell roots.
        let material = Material(domain: "TOS-QUANTUM-AUTHORIZATION-BINDING-v1", storageVersion: entry.version,
            birthHash: entry.identity.cell.hash(), globalID: entry.profile.globalID,
            rootHash: entry.profile.rootHash, fileHash: entry.profile.fileHash, operation: entry.id.uuidString.lowercased(),
            role: entry.role.rawValue, requestBytes: entry.requestBOC, requestHash: entry.requestHash,
            deadline: request.deadline, authorityHash: request.authorityHash, epoch: request.epoch,
            nonce: request.nonce, actionKind: request.kind, signingPublicKey: entry.signingPublicKey,
            deploy: entry.deploy, phase: entry.phase.rawValue, signature: OptionalBytes(entry.signature),
            signedBOC: OptionalBytes(entry.signedBOC), intent: Intent(entry.paymentIntent),
            approvalPresent: entry.feeApproval != nil, approval: entry.feeApproval)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(material)
        guard bytes.count <= 2 * 1024 * 1024 else { throw TOSPQError.invalidInput }
        digest = Data(SHA256.hash(data: bytes))
    }
    func requireSame(_ entry: TOSQuantumOutbox.Entry) throws {
        guard try self == Self(entry) else { throw TOSPQError.keyBinding }
    }
}

/// Shared by expiry and receipt readers: at most two operations globally and
/// one per birth identity, including aliases of the same identity.
internal final class TOSQuantumAuthorizationReadPermits {
    static let shared = TOSQuantumAuthorizationReadPermits()
    private let lock = NSLock()
    private var active = Set<Data>()
    func enter(_ identity: Data) throws {
        try lock.withLock {
            guard active.count < 2, !active.contains(identity) else { throw TOSQuantumAccountReader.Error.busy }
            active.insert(identity)
        }
    }
    func leave(_ identity: Data) { lock.withLock { _ = active.remove(identity) } }
}

/// Not Codable and not publicly constructible. This establishes that every
/// signature of this exact original request is past its deadline under a fresh
/// original-profile shard proof. It is separate from a payment receipt and does
/// not itself delete, archive or release an authorization.
public final class TOSQuantumExpiredAuthorization {
    public enum Error: Swift.Error { case notExpired(deadline: UInt32, provenShardTime: UInt32) }
    public let operationID: UUID
    public let deadline: UInt32
    public let provenShardTime: UInt32
    private let binding: TOSQuantumAuthorizationBinding
    private let observation: TOSQuantumAccountReader.Observation

    fileprivate init(entry: TOSQuantumOutbox.Entry, observation: TOSQuantumAccountReader.Observation,
                     now: Int64) throws {
        guard entry.identity == observation.identity, entry.profile == observation.profile else { throw TOSPQError.keyBinding }
        let request = try TOSQuantumStoredRequest(entry: entry)
        try observation.requireFresh(now: now)
        let time = try observation.proof.provenAccountTime(expectedAddress: entry.identity.address.toRaw())
        guard time > request.deadline else { throw Error.notExpired(deadline: request.deadline, provenShardTime: time) }
        binding = try TOSQuantumAuthorizationBinding(entry); self.observation = observation
        operationID = entry.id; deadline = request.deadline; provenShardTime = time
    }
    internal func retirementProvenance(entry: TOSQuantumOutbox.Entry, now: Int64) throws -> TOSQuantumRetirementSummary.Provenance {
        try requireBound(to: entry, now: now)
        return TOSQuantumRetirementSummary.Provenance(observedAt: now, provenShardTime: provenShardTime,
            masterchainTime: try observation.proof.masterchainTime(),
            targetRequest: try observation.proof.requestAtCheckpoint(account: entry.identity.address.toRaw(),
                maximumAge: TOSQuantumAccountReader.maximumAge))
    }
    /// A future durable-retirement consumer must call this under the outbox lock
    /// against the reread original entry. Local time can reject a stale proof;
    /// it never turns a nonexpired shard observation into an expiry capability.
    internal func requireBound(to entry: TOSQuantumOutbox.Entry, now: Int64) throws {
        try observation.requireFresh(now: now)
        try binding.requireSame(entry)
        guard provenShardTime > deadline else { throw TOSPQError.keyBinding }
    }
}

/// Fresh expiry observation only. No signing, broadcast, authorization write or unlink.
public final class TOSQuantumAuthorizationExpiryReader {
    private let outbox: TOSQuantumOutbox
    private let baseDirectory: URL?
    private let accounts: (TOSQuantumHistoryReader.StopFlag) throws -> TOSQuantumAccountReader
    private let now: () -> Int64

    public convenience init() throws {
        try self.init(outbox: TOSQuantumOutbox(), accounts: { flag in
            TOSQuantumAccountReader(transport: {
                guard let text = TOSRPCSettings.customEndpoint, let endpoint = URL(string: text + "/jsonRPC") else {
                    throw TOSQuantumNetworkProfile.Error.missingEndpoint
                }
                let relay = try TOSQuantumProofHTTPTransport(endpoint: endpoint)
                return { try relay.query($0, maximumBytes: $1, isCancelled: flag.stopped) }
            })
        })
    }
    internal init(outbox: TOSQuantumOutbox, baseDirectory: URL? = nil,
                  accounts: @escaping (TOSQuantumHistoryReader.StopFlag) throws -> TOSQuantumAccountReader,
                  now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.outbox = outbox; self.baseDirectory = baseDirectory; self.accounts = accounts; self.now = now
    }
    public func read(wallet: Wallet) async throws -> TOSQuantumExpiredAuthorization {
        try await read(wallet: wallet, retirementSource: nil)
    }
    internal func read(wallet: Wallet, source: TOSQuantumOutbox.RetirementSource) async throws -> TOSQuantumExpiredAuthorization {
        try await read(wallet: wallet, retirementSource: source)
    }
    private func read(wallet: Wallet, retirementSource: TOSQuantumOutbox.RetirementSource?) async throws -> TOSQuantumExpiredAuthorization {
        guard case .Quantum(let identity) = wallet.identity.kind, let id = UUID(uuidString: wallet.id),
              wallet.identity.networkGlobalId == identity.wallet.initialAuthority.globalID else { throw TOSPQError.keyBinding }
        try Task.checkCancellation()
        let birth = identity.cell.hash(), permits = TOSQuantumAuthorizationReadPermits.shared
        try permits.enter(birth); defer { permits.leave(birth) }
        let flag = TOSQuantumHistoryReader.StopFlag()
        let result: TOSQuantumExpiredAuthorization = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        guard !flag.stopped() else { throw TOSPQError.invalidInput }
                        let record = try TOSQuantumCreationRecord.load(id: id, baseDirectory: baseDirectory)
                        guard record.id == id, record.identity == identity else { throw TOSPQError.keyBinding }
                        let entry: TOSQuantumOutbox.Entry
                        if let source = retirementSource { entry = try outbox.validateRetirementSource(source) }
                        else {
                            guard let stored = try outbox.pending(identity: identity) else { throw TOSPQError.keyBinding }
                            entry = stored
                        }
                        guard entry.identity == identity, entry.profile == record.profile else { throw TOSPQError.keyBinding }
                        let observation = try accounts(flag).observeEnrolled(id: id, identity: identity, profile: record.profile)
                        let capability = try TOSQuantumExpiredAuthorization(entry: entry, observation: observation, now: now())
                        let current: TOSQuantumOutbox.Entry
                        if let source = retirementSource { current = try outbox.validateRetirementSource(source) }
                        else {
                            guard let stored = try outbox.pending(identity: identity) else { throw TOSPQError.keyBinding }
                            current = stored
                        }
                        guard !flag.stopped() else { throw TOSPQError.keyBinding }
                        try capability.requireBound(to: current, now: now())
                        continuation.resume(returning: capability)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { flag.cancel() }
        try Task.checkCancellation(); return result
    }
}
