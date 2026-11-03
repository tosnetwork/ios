import Foundation
import CoreComponents

/// Proof-backed entry point. Raw history transport never supplies initial expectations.
internal enum TOSPrivacyHistorySynchronizer {
    private static let permits = TOSQuantumAccountReader.Permits()
    final class Lease {
        let id: UUID
        private let lock = NSLock()
        private var active = false
        init(id: UUID) throws { self.id = id; try permits.enter(id); active = true }
        deinit { close() }
        func close() {
            lock.lock(); defer { lock.unlock() }
            if active { active = false; permits.leave(id) }
        }
    }
    final class Completed {
        private let lock = NSLock()
        private var observation: TOSQuantumAccountReader.PoolObservation?
        private let history: TOSPrivacyHistoryWalk.Completed
        private let lease: Lease
        fileprivate init(observation: TOSQuantumAccountReader.PoolObservation, history: TOSPrivacyHistoryWalk.Completed, lease: Lease) {
            self.observation = observation; self.history = history; self.lease = lease
        }
        deinit { close() }
        func close() {
            lock.lock(); defer { lock.unlock() }
            history.close(); observation = nil; lease.close()
        }
        func info(now: Int64) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            guard let observation else { throw TOSPrivacyHistoryWalk.Failure.stopped }
            try observation.requireFresh(now: now); return try history.info()
        }
        func transactions() throws -> [Data] {
            lock.lock(); defer { lock.unlock() }
            guard observation != nil else { throw TOSPrivacyHistoryWalk.Failure.stopped }
            return try history.transactions()
        }
        func scanAndWipeSeed(seed: inout Data, offset: Int, count: Int, now: Int64) throws -> Data {
            defer { seed.resetBytes(in: 0..<seed.count) }
            lock.lock(); defer { lock.unlock() }
            guard let observation else { throw TOSPrivacyHistoryWalk.Failure.stopped }
            try observation.requireFresh(now: now)
            return try history.scanAndWipeSeed(seed: &seed, offset: offset, count: count)
        }
        /// Call on a worker, with the operation's cancellation flag and a live
        /// clock. The original authenticated observation is checked on both sides
        /// of the complete native scan, rather than using one frozen time value.
        /// scan_next_index excludes durable reservations; this does not allocate it.
        func summaryAndWipeSeed(seed: inout Data, stopped: () -> Bool,
                               now: () -> Int64) throws -> Data {
            defer { seed.resetBytes(in: 0..<seed.count) }
            lock.lock(); defer { lock.unlock() }
            guard let observation else { throw TOSPrivacyHistoryWalk.Failure.stopped }
            return try history.summaryAndWipeSeed(seed: &seed, stopped: stopped,
                recheck: { try observation.requireFresh(now: now()) })
        }
        func receiveAndCloseMaster(_ master: TOSPrivacyMasterSession, binding: TOSPrivacyMasterSession.Binding,
                                   root: Data, stopped: () -> Bool, now: () -> Int64) throws -> Data {
            defer { master.close() }
            lock.lock(); defer { lock.unlock() }
            guard let observation else { throw TOSPrivacyHistoryWalk.Failure.stopped }
            guard binding.globalID == observation.profile.globalID, binding.birthHash == observation.birthHash,
                  binding.namespace == observation.namespace else { throw TOSPQError.keyBinding }
            let poolBinding = try observation.receiveBinding(now: now())
            return try master.receiveAndClose(history: history, binding: binding, root: root, poolBinding: poolBinding) {
                guard !stopped() else { throw TOSPrivacyHistoryWalk.Failure.stopped }
                try observation.requireFresh(now: now())
            }
        }

        func summaryAndCloseMaster(_ master: TOSPrivacyMasterSession, binding: TOSPrivacyMasterSession.Binding,
                                   stopped: () -> Bool, now: () -> Int64) throws -> Data {
            defer { master.close() }
            lock.lock(); defer { lock.unlock() }
            guard let observation else { throw TOSPrivacyHistoryWalk.Failure.stopped }
            guard binding.globalID == observation.profile.globalID, binding.birthHash == observation.birthHash,
                  binding.namespace == observation.namespace else { throw TOSPQError.keyBinding }
            return try master.summaryAndClose(history: history, binding: binding, stopped: stopped,
                recheck: { try observation.requireFresh(now: now()) })
        }
    }
    /// Balance/history reads use the configured RPC. This is not a claim that all wallet traffic uses Tor.
    static func synchronize(observation: TOSQuantumAccountReader.PoolObservation,
                            endpoint suppliedEndpoint: URL? = nil,
                            stopped: () -> Bool, now: () -> Int64, forReceive: Bool = false) throws -> Completed {
        let url: URL
        if let suppliedEndpoint { url = suppliedEndpoint }
        else {
            guard let endpoint = TOSRPCSettings.quantumEndpoint,
                  let selected = TOSRPCSettings.jsonRPCEndpoint(for: endpoint) else { throw TOSQuantumNetworkProfile.Error.missingEndpoint }
            url = selected
        }
        let relay = try TOSQuantumRPCTransport(endpoint: url)
        return try synchronize(observation: observation, query: { address, lt, hash in
            let result = try relay.call(method: "getTransactions", params: ["address": address,
                "limit": 1, "lt": String(lt), "hash": hash.base64EncodedString()], isCancelled: stopped)
            guard let rows = result as? [[String: Any]], rows.count == 1,
                  let encoded = rows[0]["data"] as? String, encoded.utf8.count <= 1_398_104,
                  let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded else { throw TOSPQError.invalidInput }
            return bytes
        }, stopped: stopped, now: now, forReceive: forReceive)
    }
    /// Query must enforce reception/timeout/cancellation caps, as the existing history transport does.
    /// Capacity remains held until the completed archive/ledger is closed, not just until fetch returns.
    static func synchronize(observation: TOSQuantumAccountReader.PoolObservation,
                            query: (String, UInt64, Data) throws -> Data, stopped: () -> Bool,
                            now: () -> Int64, forReceive: Bool = false) throws -> Completed {
        let lease = try Lease(id: observation.id)
        var succeeded = false
        defer { if !succeeded { lease.close() } }
        let history = try TOSPrivacyHistoryWalk.replay(request: observation.replayRequest(now: now(), forReceive: forReceive),
            query: query, stopped: stopped, recheck: { try observation.requireFresh(now: now()) })
        let completed = Completed(observation: observation, history: history, lease: lease)
        succeeded = true
        return completed
    }
}
