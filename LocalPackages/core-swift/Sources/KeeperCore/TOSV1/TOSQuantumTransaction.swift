import Foundation
import BigInt
import TonSwift
import CoreComponents

/// Native codec results only. The caller anchors the head in an authenticated
/// account proof and walks its committed predecessor hashes. Bodies stay opaque.
internal struct TOSQuantumTransaction {
    struct MessageValue {
        enum Kind: String { case internalMessage = "internal", externalIn = "external_in", externalOut = "external_out" }
        let hash: Data
        let bodyHash: Data
        let kind: Kind
        let source: Address?
        let destination: Address?
        let amount: BigUInt?
        let otherCurrencies: Bool
        let bounced: Bool
        let bounce: Bool?
    }
    struct ActionResult {
        let success: Bool
        let valid: Bool
        let noFunds: Bool
        let code: Int
        let skipped: UInt64
        let created: UInt64
    }
    let hash: Data
    let logicalTime: UInt64
    let previousHash: Data
    let previousLogicalTime: UInt64
    let timestamp: UInt32
    let fees: BigUInt
    let otherFeeCurrencies: Bool
    let inbound: MessageValue?
    let outbound: [MessageValue]
    let ordinary: Bool
    let computeSuccess: Bool
    let computeExitCode: Int?
    let action: ActionResult?
    let aborted: Bool
    let destroyed: Bool

    var successfulExecution: Bool {
        ordinary && computeSuccess && (computeExitCode == 0 || computeExitCode == 1) && !aborted && !destroyed &&
        (action.map { $0.success && $0.valid && !$0.noFunds && $0.code == 0 } ?? true)
    }

    /// Observes a committed outgoing transfer, not recipient credit/finality.
    /// A successful included request can still skip its +2 send entirely.
    func matchesOutgoingTransfer(externalHash: Data, sender: Address, recipient: Address,
                                 amount: BigUInt, bodyHash: Data) -> Bool {
        guard successfulExecution, amount > 0, let inbound, inbound.hash == externalHash,
              inbound.kind == .externalIn, inbound.destination == sender else { return false }
        return outbound.contains {
            $0.kind == .internalMessage && $0.source == sender && $0.destination == recipient &&
            !$0.bounced && !$0.otherCurrencies && $0.amount == amount && $0.bodyHash == bodyHash
        }
    }

    /// Strict single-payment receipt predicate. Inclusion and a matching output
    /// alone do not prove that this exact authorized operation executed fully.
    func matchesPayment(externalHash: Data, sender: Address, intent: TOSQuantumPaymentIntent) throws -> Bool {
        guard !otherFeeCurrencies, let action, action.skipped == 0, action.created == 1,
              outbound.count == 1, outbound[0].bounce == intent.bounce else { return false }
        return matchesOutgoingTransfer(externalHash: externalHash, sender: sender, recipient: intent.recipient,
            amount: intent.amount, bodyHash: try intent.internalMessage().body.hash())
    }

    init(encoded: String, expectedHash: Data, expectedLogicalTime: UInt64, address: Address) throws {
        guard address.workchain == 0, expectedHash.count == 32, expectedLogicalTime > 0,
              encoded.utf8.count <= 1_398_104, let boc = Data(base64Encoded: encoded),
              (1...1_048_576).contains(boc.count) else { throw TOSPQError.invalidInput }
        let verified = try TOSQuantumProofBridge.verifyWalletTransaction(workchain: 0, accountHash: address.hash,
            logicalTime: expectedLogicalTime, expectedHash: expectedHash, boc: boc)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let wire = try decoder.decode(Wire.self, from: verified)
        guard wire.interface == "tos-wallet-transaction/1", wire.account == address.toRaw(),
              try Self.digest(wire.hash) == expectedHash,
              try Self.time(wire.lt) == expectedLogicalTime, wire.outMsgs.count <= 256 else { throw TOSPQError.keyBinding }
        hash = expectedHash
        logicalTime = expectedLogicalTime
        previousHash = try Self.digest(wire.previousHash)
        previousLogicalTime = try Self.time(wire.previousLt)
        guard previousLogicalTime < logicalTime,
              (previousLogicalTime == 0) == previousHash.allSatisfy({ $0 == 0 }) else { throw TOSPQError.invalidInput }
        timestamp = wire.timestamp
        fees = try Self.coins(wire.fees)
        otherFeeCurrencies = wire.otherFeeCurrencies
        inbound = try wire.inMsg.map(Self.message)
        outbound = try wire.outMsgs.map(Self.message)
        guard wire.type == "ordinary" || wire.type == "other" else { throw TOSPQError.invalidInput }
        ordinary = wire.type == "ordinary"
        if ordinary {
            guard let compute = wire.compute, let aborted = wire.aborted, let destroyed = wire.destroyed else {
                throw TOSPQError.invalidInput
            }
            self.aborted = aborted; self.destroyed = destroyed
            if compute.skipped {
                guard compute.reason != nil, compute.success == nil, compute.exitCode == nil else { throw TOSPQError.invalidInput }
                computeSuccess = false; computeExitCode = nil
            } else {
                guard let success = compute.success, let code = compute.exitCode, compute.reason == nil else {
                    throw TOSPQError.invalidInput
                }
                computeSuccess = success; computeExitCode = Int(code)
            }
            action = wire.action.map { ActionResult(success: $0.success, valid: $0.valid, noFunds: $0.noFunds,
                code: Int($0.resultCode), skipped: UInt64($0.skippedActions), created: UInt64($0.messagesCreated)) }
        } else {
            guard wire.compute == nil, wire.action == nil, wire.aborted == nil, wire.destroyed == nil else {
                throw TOSPQError.invalidInput
            }
            computeSuccess = false; computeExitCode = nil; action = nil; aborted = false; destroyed = false
        }
    }

    private static func message(_ wire: WireMessage) throws -> MessageValue {
        guard let kind = MessageValue.Kind(rawValue: wire.kind) else { throw TOSPQError.invalidInput }
        let source = try wire.source.map(address), destination = try wire.destination.map(address)
        let amount: BigUInt?, other: Bool, bounced: Bool
        if kind == .internalMessage {
            guard let value = wire.value, let extra = wire.otherCurrencies, let bounce = wire.bounced,
                  wire.bounce != nil, let createdLt = wire.createdLt, wire.createdAt != nil else { throw TOSPQError.invalidInput }
            amount = try coins(value); other = extra; bounced = bounce
            _ = try time(createdLt)
        } else {
            guard wire.value == nil, wire.otherCurrencies == nil, wire.bounce == nil, wire.bounced == nil,
                  wire.createdLt == nil, wire.createdAt == nil else { throw TOSPQError.invalidInput }
            amount = nil; other = false; bounced = false
        }
        return MessageValue(hash: try digest(wire.hash), bodyHash: try digest(wire.bodyHash), kind: kind,
            source: source, destination: destination, amount: amount, otherCurrencies: other, bounced: bounced, bounce: wire.bounce)
    }
    private static func address(_ text: String) throws -> Address {
        guard text.utf8.count <= 76 else { throw TOSPQError.invalidInput }
        let value = try Address.parse(text)
        guard value.toRaw() == text else { throw TOSPQError.invalidInput }
        return value
    }
    private static func decimal(_ text: String, maximum: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= maximum && text.utf8.allSatisfy({ (48...57).contains($0) }) &&
        (text == "0" || text.first != "0")
    }
    private static func time(_ text: String) throws -> UInt64 {
        guard decimal(text, maximum: 20), let value = UInt64(text) else { throw TOSPQError.invalidInput }
        return value
    }
    private static func coins(_ text: String) throws -> BigUInt {
        guard decimal(text, maximum: 37), let value = BigUInt(text), value.bitWidth <= 120 else { throw TOSPQError.invalidInput }
        return value
    }
    private static func digest(_ text: String) throws -> Data {
        let bytes = Array(text.utf8)
        guard bytes.count == 64, bytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw TOSPQError.invalidInput
        }
        func nibble(_ byte: UInt8) -> UInt8 { byte <= 57 ? byte - 48 : byte - 87 }
        return Data(stride(from: 0, to: 64, by: 2).map { (nibble(bytes[$0]) << 4) | nibble(bytes[$0 + 1]) })
    }

    private struct Wire: Decodable {
        let interface: String, account: String, hash: String, lt: String, previousHash: String, previousLt: String
        let timestamp: UInt32
        let fees: String, otherFeeCurrencies: Bool
        let inMsg: WireMessage?, outMsgs: [WireMessage]
        let type: String, aborted: Bool?, destroyed: Bool?, compute: WireCompute?, action: WireAction?
    }
    private struct WireMessage: Decodable {
        let hash: String, bodyHash: String, kind: String
        let source: String?, destination: String?, value: String?, otherCurrencies: Bool?, bounced: Bool?, bounce: Bool?
        let createdLt: String?, createdAt: UInt32?
    }
    private struct WireCompute: Decodable {
        let skipped: Bool, success: Bool?, exitCode: Int32?, reason: Int32?
    }
    private struct WireAction: Decodable {
        let success: Bool, valid: Bool, noFunds: Bool, resultCode: Int32, skippedActions: UInt16, messagesCreated: UInt16
    }
}
