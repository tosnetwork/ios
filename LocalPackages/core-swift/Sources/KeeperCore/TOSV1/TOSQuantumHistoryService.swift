import Foundation
import BigInt

/// Presentation data from the authenticated reader. These records grant no
/// signing capability and do not assert recipient credit or a spendable balance.
public struct TOSQuantumHistoryRecord {
    public struct Message {
        public enum Kind { case internalMessage, externalIn, externalOut }
        public let kind: Kind
        public let hash: String
        public let source: String?
        public let destination: String?
        public let amountNano: String?
        public let otherCurrencies: Bool
        public let bounced: Bool
    }
    public enum Direction { case incoming, outgoing, operation }
    public enum Outcome { case included, executed, sendSkipped, executionFailed }
    public let account: String
    public let hash: String
    public let logicalTime: String
    public let timestamp: UInt32
    public let feesNano: String
    public let otherFeeCurrencies: Bool
    public let inbound: Message?
    public let outbound: [Message]
    public let direction: Direction
    public let outcome: Outcome
    public let skippedActions: UInt64

    internal init(_ value: TOSQuantumTransaction, account: String) {
        self.account = account
        hash = Self.hex(value.hash); logicalTime = String(value.logicalTime)
        timestamp = value.timestamp; feesNano = value.fees.description
        otherFeeCurrencies = value.otherFeeCurrencies
        inbound = value.inbound.map(Self.message); outbound = value.outbound.map(Self.message)
        skippedActions = value.action?.skipped ?? 0
        if let input = inbound, input.kind == .internalMessage, input.destination == account {
            direction = .incoming
            // A funded, undeployed account can skip compute and still receive
            // the message value minus fees. Execution failure is not credit failure.
            outcome = .included
        } else if outbound.contains(where: { $0.kind == .internalMessage && $0.source == account && !$0.bounced }) {
            direction = .outgoing
            outcome = .included
        } else {
            direction = .operation
            if value.successfulExecution {
                outcome = skippedActions > 0 ? .sendSkipped : .executed
            } else { outcome = value.ordinary ? .executionFailed : .included }
        }
    }

    /// Exact native-coin formatting; never converts money through floating point.
    public static func formatNano(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 37, value.utf8.allSatisfy({ (48...57).contains($0) }),
              value == "0" || value.first != "0",
              let number = BigUInt(value), number.bitWidth <= 120 else { return nil }
        let padded = String(repeating: "0", count: max(0, 10 - value.count)) + value
        let split = padded.index(padded.endIndex, offsetBy: -9)
        let whole = String(padded[..<split])
        var fraction = String(padded[split...])
        while fraction.last == "0" { fraction.removeLast() }
        return fraction.isEmpty ? whole + " TOS" : whole + "." + fraction + " TOS"
    }
    private static func hex(_ value: Data) -> String { value.map { String(format: "%02x", $0) }.joined() }
    private static func message(_ value: TOSQuantumTransaction.MessageValue) -> Message {
        let kind: Message.Kind
        switch value.kind {
        case .internalMessage: kind = .internalMessage
        case .externalIn: kind = .externalIn
        case .externalOut: kind = .externalOut
        }
        return Message(kind: kind, hash: hex(value.hash), source: value.source?.toRaw(),
            destination: value.destination?.toRaw(), amountNano: value.amount?.description,
            otherCurrencies: value.otherCurrencies, bounced: value.bounced)
    }
}

/// A UI-facing reader with no cache or signing state. The backend bounds and
/// serializes wallet reads and owns the authenticated pagination capability.
public final class TOSQuantumHistoryService {
    public enum ReadError: Swift.Error { case busy }
    public final class Cursor {
        fileprivate let value: TOSQuantumHistoryReader.Cursor
        fileprivate init(_ value: TOSQuantumHistoryReader.Cursor) { self.value = value }
    }
    public struct Page {
        public let records: [TOSQuantumHistoryRecord]
        public let next: Cursor?
        public let checkpointTime: UInt32
    }
    private let reader = TOSQuantumHistoryReader()
    public init() {}
    public func read(wallet: Wallet, cursor: Cursor? = nil) async throws -> Page {
        let page: TOSQuantumHistoryReader.Page
        do { page = try await reader.read(wallet: wallet, cursor: cursor?.value, limit: 20) }
        catch TOSQuantumAccountReader.Error.busy { throw ReadError.busy }
        let account = try wallet.address.toRaw()
        return Page(records: page.transactions.map { TOSQuantumHistoryRecord($0, account: account) },
            next: page.next.map(Cursor.init), checkpointTime: page.checkpointTime)
    }
}
