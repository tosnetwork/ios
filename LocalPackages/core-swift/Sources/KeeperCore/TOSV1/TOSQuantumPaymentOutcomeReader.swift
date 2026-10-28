import Foundation
import TonSwift
import CoreComponents

/// Read-only reconciliation of the original durable authorization. Neither RPC
/// acceptance nor an expired authorization implies that a payment was delivered.
/// This reader never signs, broadcasts, resets the journal, or releases a slot.
public final class TOSQuantumPaymentOutcomeReader {
    public enum Error: Swift.Error { case missingSignedPayment, binding, stopped }
    public enum Outcome: Equatable { case senderSent, includedWithoutExactTransfer }

    /// Minted only after walking raw transaction cells from a proven account head.
    /// Describes the sender transaction, not recipient credit or slot-release authority.
    public final class Receipt {
        public let operationID: UUID
        public let intent: TOSQuantumPaymentIntent
        public let transactionHash: Data
        public let logicalTime: UInt64
        public let timestamp: UInt32
        public let outcome: Outcome
        fileprivate init(entry: TOSQuantumOutbox.Entry, transaction: TOSQuantumTransaction) throws {
            guard let intent = entry.paymentIntent, let bytes = entry.signedBOC else { throw Error.missingSignedPayment }
            let externalHash = try TOSRPCOrdinaryBOC.decode(bytes.base64EncodedString()).hash()
            guard let inbound = transaction.inbound, inbound.kind == .externalIn,
                  inbound.destination == entry.identity.address, inbound.hash == externalHash else { throw Error.binding }
            operationID = entry.id; self.intent = intent
            transactionHash = transaction.hash; logicalTime = transaction.logicalTime; timestamp = transaction.timestamp
            outcome = try transaction.matchesPayment(externalHash: externalHash, sender: entry.identity.address,
                intent: intent) ? .senderSent : .includedWithoutExactTransfer
        }
    }
    public struct Page {
        public let operationID: UUID
        public let receipt: Receipt?
        public let next: Cursor?
        public let scannedCount: Int
        public let provenShardTime: UInt32
        /// A false value does not establish validity or permission to sign/send.
        public let authorizationExpired: Bool
        // No receipt, even after exhausting this captured history, means unverified.
    }
    public struct Cursor {
        fileprivate let walletID: UUID
        fileprivate let entry: TOSQuantumOutbox.Entry
        fileprivate let shardTime: UInt32
        fileprivate let logicalTime: UInt64
        fileprivate let hash: Data
        fileprivate let newerTimestamp: UInt32?
    }

    private let outbox: TOSQuantumOutbox
    private let baseDirectory: URL?
    private let accounts: (TOSQuantumHistoryReader.StopFlag) throws -> TOSQuantumAccountReader
    private let query: (TOSQuantumHistoryReader.StopFlag) throws -> TOSQuantumHistoryReader.Query
    private let now: () -> Int64
    private final class Permits {
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
    private static let permits = Permits()

    public convenience init() throws {
        try self.init(outbox: TOSQuantumOutbox(), accounts: { flag in
            TOSQuantumAccountReader(transport: {
                let relay = try TOSQuantumProofHTTPTransport(endpoint: Self.endpoint())
                return { try relay.query($0, maximumBytes: $1, isCancelled: flag.stopped) }
            })
        }, query: { flag in
            let relay = try TOSQuantumRPCTransport(endpoint: Self.endpoint())
            return { address, logicalTime, hash in
                let result = try relay.call(method: "getTransactions", params: ["address": address, "limit": 1,
                    "lt": String(logicalTime), "hash": hash.base64EncodedString()], isCancelled: flag.stopped)
                guard let items = result as? [[String: Any]], items.count == 1,
                      let encoded = items[0]["data"] as? String else { throw TOSPQError.invalidInput }
                return encoded
            }
        })
    }
    internal init(outbox: TOSQuantumOutbox, baseDirectory: URL? = nil,
                  accounts: @escaping (TOSQuantumHistoryReader.StopFlag) throws -> TOSQuantumAccountReader,
                  query: @escaping (TOSQuantumHistoryReader.StopFlag) throws -> TOSQuantumHistoryReader.Query,
                  now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.outbox = outbox; self.baseDirectory = baseDirectory; self.accounts = accounts
        self.query = query; self.now = now
    }
    private static func endpoint() throws -> URL {
        guard let text = TOSRPCSettings.customEndpoint, let url = URL(string: text + "/jsonRPC") else {
            throw TOSQuantumNetworkProfile.Error.missingEndpoint
        }
        return url
    }
    private static func sameAuthorization(_ a: TOSQuantumOutbox.Entry, _ b: TOSQuantumOutbox.Entry) -> Bool {
        a.id == b.id && a.identity == b.identity && a.profile == b.profile && a.role == b.role &&
        a.requestHash == b.requestHash && a.signedBOC == b.signedBOC && a.paymentIntent == b.paymentIntent && a.deploy == b.deploy
    }
    private static func deadline(_ entry: TOSQuantumOutbox.Entry) throws -> UInt32 {
        let request = try TOSRPCOrdinaryBOC.decode(entry.requestBOC.base64EncodedString())
        guard request.hash() == entry.requestHash, let intent = entry.paymentIntent else { throw Error.binding }
        try intent.requireBound(request: request, role: entry.role)
        let s = try request.beginParse()
        try s.skip(32 + 32 + 256)
        let _: Address = try s.loadType()
        try s.skip(256 + 8 + 64 + 64)
        return UInt32(try s.loadUint(bits: 32))
    }

    /// Reads the stored operation even after restart: no in-memory fee quote is
    /// required. Every page gets a fresh account observation; a continuation uses
    /// its original authenticated predecessor hash only for historical evidence.
    public func read(wallet: Wallet, cursor: Cursor? = nil, limit: Int = 20) async throws -> Page {
        guard case .Quantum(let identity) = wallet.identity.kind, let id = UUID(uuidString: wallet.id),
              wallet.identity.networkGlobalId == identity.wallet.initialAuthority.globalID,
              (1...20).contains(limit) else { throw TOSPQError.invalidInput }
        try Task.checkCancellation()
        let birthHash = identity.cell.hash()
        try Self.permits.enter(birthHash)
        defer { Self.permits.leave(birthHash) }
        let flag = TOSQuantumHistoryReader.StopFlag()
        let result: Page = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        guard !flag.stopped() else { throw Error.stopped }
                        let record = try TOSQuantumCreationRecord.load(id: id, baseDirectory: baseDirectory)
                        guard record.id == id, record.identity == identity else { throw Error.binding }
                        guard let entry = try outbox.pending(identity: identity), entry.paymentIntent != nil,
                              let bytes = entry.signedBOC,
                              [.signed, .submitting, .unknown].contains(entry.phase) else { throw Error.missingSignedPayment }
                        guard entry.profile == record.profile else { throw Error.binding }
                        if let cursor {
                            guard cursor.walletID == id, Self.sameAuthorization(cursor.entry, entry) else { throw Error.binding }
                        }
                        let observation = try accounts(flag).observeEnrolled(id: id, identity: identity, profile: record.profile)
                        try observation.requireFresh(now: now())
                        let shardTime = try observation.proof.provenAccountTime(expectedAddress: identity.address.toRaw())
                        let head = try observation.proof.provenTransactionHead(expectedAddress: identity.address.toRaw())
                        let historicalTime = cursor?.shardTime ?? shardTime
                        guard !flag.stopped() else { throw Error.stopped }
                        let externalHash = try TOSRPCOrdinaryBOC.decode(bytes.base64EncodedString()).hash()
                        let values = try TOSQuantumHistoryReader.walk(address: identity.address,
                            logicalTime: cursor?.logicalTime ?? head.logicalTime, hash: cursor?.hash ?? head.hash,
                            limit: limit, query: query(flag), stopped: flag.stopped,
                            until: { $0.inbound?.hash == externalHash })
                        guard values.transactions.allSatisfy({ $0.timestamp <= historicalTime }) else { throw TOSPQError.invalidInput }
                        if let newerTime = cursor?.newerTimestamp, let first = values.transactions.first {
                            guard first.timestamp <= newerTime else { throw TOSPQError.invalidInput }
                        }
                        let transaction = values.transactions.first { $0.inbound?.hash == externalHash }
                        let receipt = try transaction.map { try Receipt(entry: entry, transaction: $0) }
                        try observation.requireFresh(now: now())
                        guard let current = try outbox.pending(identity: identity), Self.sameAuthorization(current, entry) else {
                            throw Error.binding
                        }
                        guard !flag.stopped() else { throw Error.stopped }
                        let next = receipt == nil && values.hasMore ? Cursor(walletID: id, entry: entry,
                            shardTime: historicalTime, logicalTime: values.nextTime, hash: values.nextHash,
                            newerTimestamp: values.transactions.last?.timestamp) : nil
                        continuation.resume(returning: Page(operationID: entry.id, receipt: receipt, next: next,
                            scannedCount: values.transactions.count, provenShardTime: shardTime,
                            authorizationExpired: shardTime > (try Self.deadline(entry))))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { flag.cancel() }
        try Task.checkCancellation()
        return result
    }
}
