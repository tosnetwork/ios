import Foundation
import BigInt
import CryptoKit
import TonSwift
import CoreComponents

/// A short-lived, exact-message local estimate. Only the native capability can
/// create one. This is neither a fee guarantee nor evidence of payment.
public final class TOSQuantumPaymentQuote {
    public enum Error: Swift.Error { case notExecutable, outputMismatch, invalidBalance, binding }
    public let intent: TOSQuantumPaymentIntent
    public let operationID: UUID
    public let observedBalance: BigUInt
    public let estimatedFee: BigUInt
    public let estimatedDebit: BigUInt
    public let estimatedBalance: BigUInt
    internal let transactionFees: BigUInt
    public let expiresAt: UInt32
    internal let payment: TOSQuantumPreparedPayment
    private let simulation: TOSQuantumProofBridge.LocalSimulation
    private let message: Data
    private let quotedAt: Int64
    internal static let maximumAge: Int64 = 30

    /// Persisted confirmation, not a reusable capability. Recovery must still
    /// obtain an authenticated outcome or a fresh quote for the same signed BOC.
    public struct Approval: Codable, Equatable {
        public let messageBytesHash: Data
        public let observedBalance: String
        public let estimatedFee: String
        public let estimatedDebit: String
        public let estimatedBalance: String
        public let quotedAt: Int64
        public let expiresAt: UInt32

        internal func requireBound(message: Data, intent: TOSQuantumPaymentIntent) throws {
            let before = try TOSQuantumPaymentQuote.coins(observedBalance)
            let after = try TOSQuantumPaymentQuote.coins(estimatedBalance)
            let debit = try TOSQuantumPaymentQuote.coins(estimatedDebit)
            let fee = try TOSQuantumPaymentQuote.coins(estimatedFee)
            guard messageBytesHash == Data(SHA256.hash(data: message)), before >= after,
                  before - after == debit, debit >= intent.amount, debit - intent.amount == fee,
                  quotedAt > 0, quotedAt < Int64(expiresAt) else { throw TOSPQError.keyBinding }
        }
    }

    internal var approval: Approval {
        Approval(messageBytesHash: Data(SHA256.hash(data: message)), observedBalance: String(observedBalance),
            estimatedFee: String(estimatedFee), estimatedDebit: String(estimatedDebit),
            estimatedBalance: String(estimatedBalance), quotedAt: quotedAt, expiresAt: expiresAt)
    }

    internal init(payment: TOSQuantumPreparedPayment, entry: TOSQuantumOutbox.Entry,
                  simulation: TOSQuantumProofBridge.LocalSimulation, now: Int64) throws {
        try payment.requireFresh(now: now)
        guard entry.identity == payment.identity, entry.profile == payment.profile,
              entry.requestHash == payment.request.digest, entry.role == .primary,
              entry.paymentIntent == payment.intent, entry.deploy == payment.requiresDeployment,
              [.signed, .submitting, .unknown].contains(entry.phase), let message = entry.signedBOC else { throw Error.binding }
        try simulation.requireBinding(anchor: payment.profile.anchor(), request: payment.simulationRequest(),
            signedMessage: message, now: now, maximumAge: Self.maximumAge)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard try decoder.decode(Status.self, from: simulation.encoded).status == "executed" else { throw Error.notExecutable }
        let wire = try decoder.decode(Wire.self, from: simulation.encoded)
        guard wire.status == "executed", let tx = wire.transaction else { throw Error.notExecutable }
        let codec = tx.codec
        let root = try TOSRPCOrdinaryBOC.decode(message.base64EncodedString()).hash()
        let address = payment.identity.address.toRaw()
        guard wire.account.address == address, codec.account == address,
              try Self.digest(wire.messageRootHash) == root, codec.type == "ordinary",
              !codec.aborted, !codec.destroyed, !codec.otherFeeCurrencies,
              !codec.compute.skipped, codec.compute.success == true,
              codec.compute.exitCode == 0 || codec.compute.exitCode == 1,
              let action = codec.action, action.success, action.valid, !action.noFunds,
              action.resultCode == 0, action.skippedActions == 0, action.messagesCreated == 1,
              codec.inMsg?.kind == "external_in", codec.inMsg?.destination == address,
              try codec.inMsg.map({ try Self.digest($0.hash) }) == root else { throw Error.notExecutable }
        let body = try payment.intent.internalMessage().body.hash()
        guard codec.outMsgs.count == 1, let out = codec.outMsgs.first,
              out.kind == "internal", out.source == address, out.destination == payment.intent.recipient.toRaw(),
              out.bounced == false, out.bounce == payment.intent.bounce, out.otherCurrencies == false,
              try out.value.map(Self.coins) == payment.intent.amount,
              try Self.digest(out.bodyHash) == body else { throw Error.outputMismatch }
        let before = try Self.coins(wire.account.observedBalance)
        let after = try Self.coins(tx.expectedBalance)
        transactionFees = try Self.coins(codec.fees)
        guard before >= after else { throw Error.invalidBalance }
        let debit = before - after
        guard debit >= payment.intent.amount else { throw Error.invalidBalance }
        observedBalance = before; estimatedBalance = after; estimatedDebit = debit
        estimatedFee = debit - payment.intent.amount
        intent = payment.intent; operationID = entry.id
        expiresAt = UInt32(min(Int64(payment.expiresAt), simulation.verifiedAt + Self.maximumAge))
        self.payment = payment; self.simulation = simulation; self.message = message; quotedAt = now
    }

    internal func requireFresh(entry: TOSQuantumOutbox.Entry, now: Int64) throws {
        try payment.requireFresh(now: now)
        try requireSameEntry(entry)
        try simulation.requireBinding(anchor: payment.profile.anchor(), request: payment.simulationRequest(),
            signedMessage: message, now: now, maximumAge: Self.maximumAge)
    }

    internal func requireSameEntry(_ entry: TOSQuantumOutbox.Entry) throws {
        guard entry.id == operationID, entry.identity == payment.identity, entry.profile == payment.profile,
              entry.requestHash == payment.request.digest, entry.paymentIntent == intent,
              entry.deploy == payment.requiresDeployment, entry.role == .primary,
              [.signed, .submitting, .unknown].contains(entry.phase), entry.signedBOC == message else { throw Error.binding }
    }

    private static func coins(_ value: String) throws -> BigUInt {
        guard !value.isEmpty, value.utf8.count <= 37, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = BigUInt(value), number.bitWidth <= 120, String(number) == value else { throw TOSPQError.invalidInput }
        return number
    }
    private static func digest(_ value: String) throws -> Data {
        let bytes = Array(value.utf8)
        guard bytes.count == 64, bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw TOSPQError.invalidInput
        }
        func nibble(_ byte: UInt8) -> UInt8 { byte <= 57 ? byte - 48 : byte - 87 }
        return Data(stride(from: 0, to: 64, by: 2).map { (nibble(bytes[$0]) << 4) | nibble(bytes[$0 + 1]) })
    }
    private struct Wire: Decodable {
        let status: String, messageRootHash: String
        let account: Account
        let transaction: Transaction?
    }
    private struct Status: Decodable { let status: String }
    private struct Account: Decodable { let address: String, observedBalance: String }
    private struct Transaction: Decodable { let codec: Codec, expectedBalance: String }
    private struct Codec: Decodable {
        let account: String, type: String, fees: String, aborted: Bool, destroyed: Bool, otherFeeCurrencies: Bool
        let compute: Compute, action: Action?, inMsg: Message?, outMsgs: [Message]
    }
    private struct Compute: Decodable { let skipped: Bool, success: Bool?, exitCode: Int32? }
    private struct Action: Decodable {
        let success: Bool, valid: Bool, noFunds: Bool, resultCode: Int32, skippedActions: UInt16, messagesCreated: UInt16
    }
    private struct Message: Decodable {
        let kind: String, hash: String, bodyHash: String
        let source: String?, destination: String?, value: String?, bounced: Bool?, bounce: Bool?, otherCurrencies: Bool?
    }
}
