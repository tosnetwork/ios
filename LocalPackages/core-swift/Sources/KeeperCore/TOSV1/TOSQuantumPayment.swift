import Foundation
import BigInt
import TonSwift
import CoreComponents

/// Exact user-visible native-coin intent. This contains no fee estimate or signing
/// authority. Amounts are persisted as canonical decimal strings, never Doubles.
public struct TOSQuantumPaymentIntent: Codable, Equatable {
    public let recipient: Address
    public let amount: BigUInt
    public let bounce: Bool
    public let comment: String?
    public static let maximumCommentBytes = 4096

    public init(recipient: Address, amount: BigUInt, bounce: Bool, comment: String? = nil) throws {
        guard recipient.hash.count == 32, amount > 0, amount.bitWidth <= 120,
              (comment?.utf8.count ?? 0) <= Self.maximumCommentBytes else { throw TOSPQError.invalidInput }
        self.recipient = recipient; self.amount = amount; self.bounce = bounce
        self.comment = comment?.isEmpty == true ? nil : comment
    }

    public func actions() throws -> Cell {
        let message = try comment.map {
            try MessageRelaxed.internal(to: recipient, value: amount, bounce: bounce, textPayload: $0)
        } ?? MessageRelaxed.internal(to: recipient, value: amount, bounce: bounce)
        return try Builder().store(uint: 0x0ec3c86d, bits: 32).store(uint: 3, bits: 8)
            .store(ref: Builder().endCell()).store(ref: Builder().store(message)).endCell()
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.recipient == rhs.recipient && lhs.amount == rhs.amount && lhs.bounce == rhs.bounce &&
            lhs.comment.map { Data($0.utf8) } == rhs.comment.map { Data($0.utf8) }
    }

    internal func requireBound(request: Cell, role: TOSQuantumRole) throws {
        let payload = try Builder().store(uint: 0x45584543, bits: 32).store(ref: actions()).endCell()
        guard role == .primary, request.refs.count == 1, request.refs[0].hash() == payload.hash() else {
            throw TOSPQError.keyBinding
        }
        let s = try request.beginParse()
        guard s.remainingBits == 1019 else { throw TOSPQError.keyBinding }
        try s.skip(1011)
        guard try s.loadUint(bits: 8) == 0 else { throw TOSPQError.keyBinding }
    }

    private enum CodingKeys: String, CodingKey { case version, recipient, amount, bounce, comment }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decimal = try c.decode(String.self, forKey: .amount)
        guard try c.decode(UInt8.self, forKey: .version) == 1, decimal.utf8.count <= 37,
              let amount = BigUInt(decimal), String(amount) == decimal else { throw TOSPQError.invalidInput }
        try self.init(recipient: Address.parse(c.decode(String.self, forKey: .recipient)), amount: amount,
            bounce: c.decode(Bool.self, forKey: .bounce), comment: c.decodeIfPresent(String.self, forKey: .comment))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(UInt8(1), forKey: .version)
        try c.encode(recipient.toRaw(), forKey: .recipient)
        try c.encode(String(amount), forKey: .amount)
        try c.encode(bounce, forKey: .bounce)
        try c.encodeIfPresent(comment, forKey: .comment)
    }
}

/// A proof-bound unsigned payment, for the dedicated confirmation flow. The
/// balance here is not spendable-after-fees and this type does not approve fees.
public struct TOSQuantumPreparedPayment {
    public enum Error: Swift.Error { case insufficientValue, frozenAccount, expired }
    public let intent: TOSQuantumPaymentIntent
    public let identity: TOSQuantumSelfPayIdentity
    public let profile: TOSQuantumNetworkProfile
    public let request: TOSQuantumSelfPayRequest
    public let requiresDeployment: Bool
    public let observedBalance: BigUInt
    public let expiresAt: UInt32
    private let observation: TOSQuantumAccountReader.Observation
    private let network: TOSQuantumSelfPayNetwork

    internal init(observation: TOSQuantumAccountReader.Observation, intent: TOSQuantumPaymentIntent,
                  now: Int64, ttl: UInt32) throws {
        guard now > 0, now <= Int64(UInt32.max), (1...3600).contains(ttl) else { throw TOSPQError.invalidInput }
        try observation.requireFresh(now: now)
        let network = try TOSQuantumSelfPayNetwork(proof: observation.network,
            expectedGlobalID: observation.profile.globalID, now: now, maximumAge: TOSQuantumAccountReader.maximumAge)
        try network.requireSameCheckpoint(observation.proof, now: now)
        try observation.identity.requireNetwork(globalID: network.globalID, namespace: network.namespace)
        let state: TOSQuantumSelfPayState
        switch observation.snapshot.status {
        case .active(let current): state = current; requiresDeployment = false
        case .absent, .uninitialized:
            state = try TOSQuantumSelfPayState.parse(observation.identity.wallet.initialData)
            requiresDeployment = true
        case .frozen: throw Error.frozenAccount
        }
        guard observation.snapshot.balance >= intent.amount else { throw Error.insufficientValue }
        let accountTime = try observation.proof.provenAccountTime(expectedAddress: observation.identity.address.toRaw())
        let time = max(UInt32(now), max(try observation.network.masterchainTime(), accountTime))
        guard UInt64(time) + UInt64(ttl) <= UInt64(UInt32.max) else { throw TOSPQError.invalidInput }
        let deadline = time + ttl
        let policy = try TOSRPCOrdinaryBOC.decode(observation.network.provenConfigParam(48).base64EncodedString())
        request = try TOSQuantumSelfPayRequest(wallet: observation.identity.address, state: state, role: .primary,
            validUntil: deadline, action: .execute(intent.actions()), provenTime: time, primaryPolicy: policy)
        self.observation = observation; self.network = network
        self.intent = intent; identity = observation.identity; profile = observation.profile
        observedBalance = observation.snapshot.balance; expiresAt = deadline
    }

    public func requireFresh(now: Int64) throws {
        try observation.requireFresh(now: now)
        try network.requireSameCheckpoint(observation.proof, now: now)
        guard now > 0, now < Int64(expiresAt) else { throw Error.expired }
    }
}

public final class TOSQuantumPaymentService {
    private let reader: TOSQuantumAccountReader
    private let now: () -> Int64
    public convenience init() {
        self.init(reader: TOSQuantumAccountReader(), now: { Int64(Date().timeIntervalSince1970) })
    }
    internal init(reader: TOSQuantumAccountReader, now: @escaping () -> Int64) {
        self.reader = reader; self.now = now
    }
    /// No key access, reservation or broadcast happens during preview. A later
    /// confirmation must validate fees and recheck this capability's freshness.
    public func prepare(wallet: Wallet, intent: TOSQuantumPaymentIntent, ttl: UInt32 = 120) async throws -> TOSQuantumPreparedPayment {
        guard (1...3600).contains(ttl) else { throw TOSPQError.invalidInput }
        guard case .Quantum(let identity) = wallet.identity.kind,
              wallet.identity.networkGlobalId == identity.wallet.initialAuthority.globalID else { throw TOSPQError.keyBinding }
        let observation = try await reader.observe(wallet: wallet, configIndices: [8, 19, 48])
        try Task.checkCancellation()
        return try TOSQuantumPreparedPayment(observation: observation, intent: intent, now: now(), ttl: ttl)
    }
}
