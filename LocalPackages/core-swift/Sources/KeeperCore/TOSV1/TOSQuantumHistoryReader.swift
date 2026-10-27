import Foundation
import TonSwift
import CoreComponents

/// Authenticated transaction cells, anchored in the same fresh account proof
/// used by the balance reader. RPC metadata never supplies success or amounts.
internal final class TOSQuantumHistoryReader {
    struct Page {
        let transactions: [TOSQuantumTransaction]
        let next: Cursor?
        let checkpointTime: UInt32
        var hasMore: Bool { next != nil }
    }
    struct Cursor {
        fileprivate let observation: TOSQuantumAccountReader.Observation
        fileprivate let logicalTime: UInt64
        fileprivate let hash: Data
    }
    typealias Query = (String, UInt64, Data) throws -> String
    private let accounts: TOSQuantumAccountReader
    private let query: (StopFlag) throws -> Query
    private let now: () -> Int64
    private static let permits = TOSQuantumAccountReader.Permits()

    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private let deadline = DispatchTime.now() + 60
        func cancel() { lock.withLock { cancelled = true } }
        func stopped() -> Bool { lock.withLock { cancelled || DispatchTime.now() >= deadline } }
    }

    convenience init(accounts: TOSQuantumAccountReader = TOSQuantumAccountReader()) {
        self.init(accounts: accounts, query: { flag in
            guard let endpoint = TOSRPCSettings.customEndpoint,
                  let url = URL(string: endpoint + "/jsonRPC") else { throw TOSQuantumNetworkProfile.Error.missingEndpoint }
            let relay = try TOSQuantumRPCTransport(endpoint: url)
            return { address, logicalTime, hash in
                let result = try relay.call(method: "getTransactions", params: ["address": address,
                    "limit": 1, "lt": String(logicalTime), "hash": hash.base64EncodedString()], isCancelled: flag.stopped)
                guard let items = result as? [[String: Any]], items.count == 1,
                      let encoded = items[0]["data"] as? String else { throw TOSPQError.invalidInput }
                return encoded
            }
        })
    }
    init(accounts: TOSQuantumAccountReader, query: @escaping (StopFlag) throws -> Query,
         now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.accounts = accounts; self.query = query; self.now = now
    }

    func read(wallet: Wallet, cursor: Cursor? = nil, limit: Int = 20) async throws -> Page {
        guard case .Quantum(let identity) = wallet.identity.kind, let id = UUID(uuidString: wallet.id), (1...20).contains(limit) else {
            throw TOSPQError.invalidInput
        }
        if let cursor {
            guard cursor.observation.id == id, cursor.observation.identity == identity else { throw TOSPQError.keyBinding }
        }
        try Task.checkCancellation()
        try Self.permits.enter(id)
        defer { Self.permits.leave(id) }
        let flag = StopFlag()
        return try await withTaskCancellationHandler {
            let observation: TOSQuantumAccountReader.Observation
            if let cursor { observation = cursor.observation }
            else { observation = try await accounts.observe(wallet: wallet) }
            try Task.checkCancellation()
            let result: Page = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let address = observation.identity.address
                        let raw = address.toRaw()
                        try observation.requireFresh(now: self.now())
                        let head = try observation.proof.provenTransactionHead(expectedAddress: raw)
                        let time = cursor?.logicalTime ?? head.logicalTime, hash = cursor?.hash ?? head.hash
                        let values = try Self.walk(address: address, logicalTime: time, hash: hash,
                                                   limit: limit, query: self.query(flag), stopped: flag.stopped)
                        let shardTime = try observation.proof.provenAccountTime(expectedAddress: raw)
                        guard values.transactions.allSatisfy({ $0.timestamp <= shardTime }) else { throw TOSPQError.invalidInput }
                        try observation.requireFresh(now: self.now())
                        guard !flag.stopped() else { throw TOSPQError.invalidInput }
                        let next = values.hasMore ? Cursor(observation: observation, logicalTime: values.nextTime, hash: values.nextHash) : nil
                        continuation.resume(returning: Page(transactions: values.transactions, next: next,
                            checkpointTime: try observation.network.masterchainTime()))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: { flag.cancel() }
    }

    /// Hash-chain codec only. The production caller above obtains its head from
    /// provenTransactionHead, rather than an RPC transaction_id or caller input.
    static func walk(address: Address, logicalTime: UInt64, hash: Data, limit: Int,
                     query: Query, stopped: () -> Bool = { false }) throws -> (transactions: [TOSQuantumTransaction], hasMore: Bool, nextTime: UInt64, nextHash: Data) {
        guard (1...20).contains(limit), hash.count == 32,
              (logicalTime == 0) == hash.allSatisfy({ $0 == 0 }) else { throw TOSPQError.invalidInput }
        var nextTime = logicalTime, nextHash = hash, values = [TOSQuantumTransaction]()
        while nextTime != 0 && values.count < limit {
            guard !stopped() else { throw TOSPQError.invalidInput }
            let encoded = try query(address.toRaw(), nextTime, nextHash)
            let transaction = try TOSQuantumTransaction(encoded: encoded, expectedHash: nextHash,
                                                       expectedLogicalTime: nextTime, address: address)
            if let newer = values.last {
                guard transaction.timestamp <= newer.timestamp else { throw TOSPQError.invalidInput }
            }
            values.append(transaction)
            nextTime = transaction.previousLogicalTime; nextHash = transaction.previousHash
        }
        guard !stopped() else { throw TOSPQError.invalidInput }
        return (values, nextTime != 0, nextTime, nextHash)
    }
}
