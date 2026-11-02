import Foundation
import BigInt
import TonSwift
import CoreComponents

/// Exact user-visible native-coin or standard Token intent. This contains no fee estimate or signing
/// authority. Amounts are persisted as canonical decimal strings, never Doubles.
public struct TOSQuantumPaymentIntent: Codable, Equatable {
    public let recipient: Address
    public let amount: BigUInt
    public let bounce: Bool
    public let comment: String?
    public let tokenTransfer: TOSQuantumTokenTransferIntent?
    public static let maximumCommentBytes = 4096

    public init(recipient: Address, amount: BigUInt, bounce: Bool, comment: String? = nil) throws {
        guard recipient.hash.count == 32, amount > 0, amount.bitWidth <= 120,
              (comment?.utf8.count ?? 0) <= Self.maximumCommentBytes else { throw TOSPQError.invalidInput }
        self.recipient = recipient; self.amount = amount; self.bounce = bounce
        self.comment = comment?.isEmpty == true ? nil : comment
        self.tokenTransfer = nil
    }

    public init(tokenTransfer: TOSQuantumTokenTransferIntent) {
        self.tokenTransfer = tokenTransfer
        recipient = tokenTransfer.wallet; amount = tokenTransfer.attachedTos
        bounce = true; comment = nil
    }

    /// Exact TOS decimal input, without locale, exponent or floating-point conversion.
    public static func parseAmount(_ decimal: String) throws -> BigUInt {
        guard (1...47).contains(decimal.utf8.count) else { throw TOSPQError.invalidInput }
        let parts = decimal.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let whole = parts.first, !whole.isEmpty,
              whole.utf8.allSatisfy({ (48...57).contains($0) }),
              whole == "0" || whole.first != "0" else { throw TOSPQError.invalidInput }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard (parts.count == 1 || !fraction.isEmpty), fraction.utf8.count <= 9,
              fraction.utf8.allSatisfy({ (48...57).contains($0) }),
              let integer = BigUInt(String(whole)),
              let fractional = BigUInt(fraction + String(repeating: "0", count: 9 - fraction.utf8.count)) else {
            throw TOSPQError.invalidInput
        }
        let value = integer * 1_000_000_000 + fractional
        guard value > 0, value.bitWidth <= 120 else { throw TOSPQError.invalidInput }
        return value
    }

    public func actions() throws -> Cell {
        let message = try internalMessage()
        return try Builder().store(uint: 0x0ec3c86d, bits: 32).store(uint: 3, bits: 8)
            .store(ref: Builder().endCell()).store(ref: Builder().store(message)).endCell()
    }

    internal func internalMessage() throws -> MessageRelaxed {
        if let tokenTransfer {
            return try MessageRelaxed.internal(to: tokenTransfer.wallet, value: tokenTransfer.attachedTos,
                bounce: true, body: tokenTransfer.body())
        }
        return try comment.map {
            try MessageRelaxed.internal(to: recipient, value: amount, bounce: bounce, textPayload: $0)
        } ?? MessageRelaxed.internal(to: recipient, value: amount, bounce: bounce, body: Builder().endCell())
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.recipient == rhs.recipient && lhs.amount == rhs.amount && lhs.bounce == rhs.bounce &&
            lhs.comment.map { Data($0.utf8) } == rhs.comment.map { Data($0.utf8) } && lhs.tokenTransfer == rhs.tokenTransfer
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

    private enum CodingKeys: String, CodingKey { case version, recipient, amount, bounce, comment, tokenTransfer }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decimal = try c.decode(String.self, forKey: .amount)
        guard try c.decode(UInt8.self, forKey: .version) == 1, decimal.utf8.count <= 37,
              let amount = BigUInt(decimal), String(amount) == decimal else { throw TOSPQError.invalidInput }
        let recipient = try Address.parse(c.decode(String.self, forKey: .recipient))
        let bounce = try c.decode(Bool.self, forKey: .bounce)
        let comment = try c.decodeIfPresent(String.self, forKey: .comment)
        if let token = try c.decodeIfPresent(TOSQuantumTokenTransferIntent.self, forKey: .tokenTransfer) {
            guard recipient == token.wallet, amount == token.attachedTos, bounce, comment == nil else {
                throw TOSPQError.keyBinding
            }
            self.init(tokenTransfer: token)
        } else {
            try self.init(recipient: recipient, amount: amount, bounce: bounce, comment: comment)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(UInt8(1), forKey: .version)
        try c.encode(recipient.toRaw(), forKey: .recipient)
        try c.encode(String(amount), forKey: .amount)
        try c.encode(bounce, forKey: .bounce)
        try c.encodeIfPresent(comment, forKey: .comment)
        try c.encodeIfPresent(tokenTransfer, forKey: .tokenTransfer)
    }
}

/// A proof-bound unsigned payment, for the dedicated confirmation flow. The
/// balance here is not spendable-after-fees and this type does not approve fees.
public struct TOSQuantumPreparedPayment {
    public enum Error: Swift.Error { case insufficientValue, insufficientTokenBalance, frozenAccount, expired }
    public let intent: TOSQuantumPaymentIntent
    public let identity: TOSQuantumSelfPayIdentity
    public let profile: TOSQuantumNetworkProfile
    public let request: TOSQuantumSelfPayRequest
    public let requiresDeployment: Bool
    public let observedBalance: BigUInt
    public let expiresAt: UInt32
    private let observation: TOSQuantumAccountReader.Observation
    private let network: TOSQuantumSelfPayNetwork
    private let tokenObservation: TOSQuantumAccountReader.TokenObservation?
    internal var walletID: UUID { observation.id }

    internal func simulationRequest() throws -> Data {
        // Account and configuration are authenticated at the simulator's latest
        // target. An intervening read may already have advanced the checkpoint.
        try JSONSerialization.data(withJSONObject: ["mode": "live", "account": identity.address.toRaw(),
            "max_age_seconds": TOSQuantumAccountReader.maximumAge], options: [.sortedKeys])
    }

    internal init(observation: TOSQuantumAccountReader.Observation, intent: TOSQuantumPaymentIntent,
                  now: Int64, ttl: UInt32, tokenObservation: TOSQuantumAccountReader.TokenObservation? = nil) throws {
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
        if let token = intent.tokenTransfer {
            guard let checked = tokenObservation, token.owner == observation.identity.address,
                  checked.owner.id == observation.id, checked.owner.identity == observation.identity,
                  checked.master == token.master, checked.wallet == token.wallet else { throw TOSPQError.keyBinding }
            try observation.network.requireSameCheckpoint(checked.owner.proof)
            try checked.requireFresh(now: now)
            let content = try TOSTokenContent.decode(checked.masterState.content)
            let decimals: Int
            if let value = content.decimals { decimals = value }
            else if let uri = content.uri { decimals = try TOSTokenMetadata.read(uri, isCancelled: { false }).decimals }
            else { throw TOSPQError.invalidInput }
            guard decimals == token.decimals else { throw TOSPQError.keyBinding }
            guard checked.balance >= token.units else { throw Error.insufficientTokenBalance }
        } else if tokenObservation != nil { throw TOSPQError.keyBinding }
        self.tokenObservation = tokenObservation
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

    /// Rebuild only the same request from current authenticated state. A consumed,
    /// expired or reconfigured authorization cannot become a replacement request.
    internal init(recovering entry: TOSQuantumOutbox.Entry,
                  observation: TOSQuantumAccountReader.Observation, now: Int64,
                  tokenObservation: TOSQuantumAccountReader.TokenObservation? = nil) throws {
        guard entry.identity == observation.identity, entry.profile == observation.profile,
              let intent = entry.paymentIntent, entry.signedBOC != nil,
              entry.phase == .signed, now > 0, now <= Int64(UInt32.max) else {
            throw TOSPQError.keyBinding
        }
        let deadline = try TOSQuantumStoredRequest(entry: entry).deadline
        let time = max(UInt32(now), max(try observation.network.masterchainTime(),
            try observation.proof.provenAccountTime(expectedAddress: entry.identity.address.toRaw())))
        guard deadline > time else { throw Error.expired }
        try self.init(observation: observation, intent: intent, now: now, ttl: deadline - time, tokenObservation: tokenObservation)
        guard request.digest == entry.requestHash,
              requiresDeployment == entry.deploy else { throw TOSPQError.keyBinding }
    }

    public func requireFresh(now: Int64) throws {
        try observation.requireFresh(now: now)
        try network.requireSameCheckpoint(observation.proof, now: now)
        try tokenObservation?.requireFresh(now: now)
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
        let tokenObservation = try intent.tokenTransfer.map {
            try reader.observeToken(owner: observation, master: $0.master, wallet: $0.wallet)
        }
        try Task.checkCancellation()
        return try TOSQuantumPreparedPayment(observation: observation, intent: intent, now: now(), ttl: ttl,
            tokenObservation: tokenObservation)
    }
}
