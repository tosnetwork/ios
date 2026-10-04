import Foundation
import CoreFoundation
import TonSwift
import CoreComponents

public enum TOSPQOperationStatus: String, Codable {
    case pending, feeAccepted, authAccepted, deployed, delivered, failed, expired
    public var terminal: Bool { self == .deployed || self == .delivered || self == .failed || self == .expired }
}
/// Public submission metadata only; no seed, password or expanded key is stored.
public struct TOSPQPendingOperation: Codable {
    public let feeAddress: String
    public let externalHash: String
    public let moduleAddress: String
    public let walletAddress: String
    public let recipient: String?
    public let amount: UInt64
    public let seqno: UInt32
    public let expires: UInt32
    public var status: TOSPQOperationStatus
    public init(feeAddress: String, externalHash: String, moduleAddress: String, walletAddress: String, recipient: String?, amount: UInt64, seqno: UInt32, expires: UInt32) {
        self.feeAddress = feeAddress;self.externalHash = externalHash;self.moduleAddress = moduleAddress;self.walletAddress = walletAddress
        self.recipient = recipient;self.amount = amount;self.seqno = seqno;self.expires = expires;self.status = .pending
    }
}
public enum TOSPQReceipt {
    public static func reconcile(_ intent: TOSPQPendingOperation, history: (String) async throws -> [[String: Any]], deployed: () async throws -> Bool) async throws -> TOSPQOperationStatus {
        func receipt(_ address: String, _ hash: String) async throws -> [String: Any]? {
            try await history(address).first { $0["in_msg_hash"] as? String == hash }
        }
        guard let fee = try await receipt(intent.feeAddress, intent.externalHash) else { return .pending }
        guard try successful(fee) else { return try rejected(fee) ? .failed : .pending }
        guard let recipientAddress = intent.recipient else { return try await deployed() ? .deployed : .feeAccepted }
        let moduleInputs = try outgoing(fee).filter { try destination($0) == Address.parse(intent.moduleAddress) }
        guard moduleInputs.count == 1, let moduleHash = moduleInputs[0]["hash"] as? String,
            let module = try await receipt(intent.moduleAddress, moduleHash) else { return .feeAccepted }
        guard try successful(module) else { return try rejected(module) ? .failed : .feeAccepted }
        let walletInputs = try outgoing(module).filter { try destination($0) == Address.parse(intent.walletAddress) }
        guard walletInputs.count == 1, let walletHash = walletInputs[0]["hash"] as? String,
            let wallet = try await receipt(intent.walletAddress, walletHash) else { return .authAccepted }
        guard try successful(wallet) else { return try rejected(wallet) ? .failed : .authAccepted }
        let outputs = try outgoing(wallet)
        guard outputs.count == 1 else { throw TOSPQError.keyBinding }
        let sent = outputs[0]
        guard try destination(sent) == Address.parse(recipientAddress), sent["kind"] as? String == "internal", boolean(sent["bounced"]) == false,
            let value = sent["value"] as? String, UInt64(value) == intent.amount, let hash = sent["hash"] as? String else { throw TOSPQError.keyBinding }
        guard let recipient = try await receipt(recipientAddress, hash) else { return .authAccepted }
        guard let incoming = recipient["in_msg"] as? [String: Any], try destination(incoming) == Address.parse(recipientAddress),
            boolean(incoming["bounced"]) == false, let received = incoming["value"] as? String, UInt64(received) == intent.amount else { throw TOSPQError.keyBinding }
        let compute = recipient["compute"] as? [String: Any]
        let recipientOutputs = try outgoing(recipient)
        let passive = recipient["transaction_type"] as? String == "ordinary" && boolean(recipient["aborted"]) == true &&
            boolean(compute?["skipped"]) == true && integer(compute?["skip_reason"]) == 0 && recipient["action"] is NSNull &&
            recipientOutputs.isEmpty && (recipient["fee"] as? String).flatMap(UInt64.init).map { $0 < intent.amount } == true
        // Passive credit is an exact incoming-message receipt, not compute success.
        if successfulRecipient(recipient) || passive { return .delivered }
        return try rejected(recipient) ? .failed : .authAccepted
    }
    private static func rejected(_ tx: [String: Any]) throws -> Bool {
        let messages = try outgoing(tx)
        return boolean(tx["aborted"]) == true && messages.allSatisfy { boolean($0["bounced"]) == true }
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func integer(_ value: Any?) -> UInt64? { (value as? NSNumber).flatMap(TOSWalletRPC.unsignedInteger) }
    private static func destination(_ msg: [String: Any]) throws -> Address {
        guard let raw = msg["destination"] as? String else { throw TOSPQError.invalidInput };return try Address.parse(raw)
    }
    private static func outgoing(_ tx: [String: Any]) throws -> [[String: Any]] {
        guard let messages = tx["out_msgs"] as? [[String: Any]] else { throw TOSPQError.invalidInput };return messages
    }
    private static func successfulRecipient(_ tx: [String: Any]) -> Bool {
        guard let c = tx["compute"] as? [String: Any] else { return false }
        let a = tx["action"] as? [String: Any]
        return tx["transaction_type"] as? String == "ordinary" && boolean(tx["aborted"]) == false && boolean(c["skipped"]) == false &&
            boolean(c["success"]) == true && integer(c["exit_code"]) == 0 && (a == nil ||
                (boolean(a?["success"]) == true && boolean(a?["valid"]) == true && boolean(a?["no_funds"]) == false && integer(a?["result_code"]) == 0 && integer(a?["skipped_actions"]) == 0))
    }
    private static func successful(_ tx: [String: Any]) throws -> Bool {
        guard let action = tx["action"] as? [String: Any] else { return false }
        let messages = try outgoing(tx)
        return successfulRecipient(tx) && integer(action["messages_created"]) == UInt64(messages.count) && !messages.isEmpty
    }
}
extension TOSPQNodeSession {
    public func pqReconcile(_ pending: TOSPQPendingOperation, wallet: TOSPQWallet) async throws -> TOSPQOperationStatus {
        try await TOSPQReceipt.reconcile(pending, history: { address in try await node.callTransactions(address: Address.parse(address), limit: 64) },
            deployed: { _ = try await pqSnapshot(wallet: wallet);return true })
    }
}
