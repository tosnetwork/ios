import Foundation

/// Bounded raw-history orchestration, not an authenticator of caller expectations.
/// Wallet entry points must construct request/recheck from one verified observation.
public enum TOSPrivacyHistoryWalk {
    public enum Failure: Error { case malformed, incomplete, stopped, limit }
    public static let maximumTransactions = 8192
    public static let maximumArchiveBytes = 32 * 1024 * 1024
    private static let maximumTransactionBytes = 1024 * 1024

    public final class Completed {
        private let replay: TOSPrivacyNative.Replay
        private let lock = NSLock()
        private var archive: [Data]?
        fileprivate init(replay: TOSPrivacyNative.Replay, transactions: [Data]) {
            self.replay = replay; self.archive = transactions
        }
        deinit { close() }
        public func transactions() throws -> [Data] {
            lock.lock(); defer { lock.unlock() }
            guard let archive else { throw Failure.stopped }
            return archive
        }
        public func close() {
            lock.lock(); defer { lock.unlock() }
            replay.close(); archive = nil
        }
        public func info() throws -> Data { try replay.info() }
        public func scanAndWipeSeed(seed: inout Data, offset: Int, count: Int) throws -> Data {
            try replay.scanAndWipeSeed(seed: &seed, offset: offset, count: count)
        }
        /// Blocking worker operation over the complete ledger, never a sum of
        /// batch balances. Recheck the original proof before and after native work;
        /// callbacks must not reenter this owner. No result survives cancellation
        /// or a failed final proof recheck. The caller still persists reservations.
        public func loadPaymentProver(phase1: URL, ceremony: URL) throws -> TOSPrivacyNative.PaymentProver {
            try replay.loadPaymentProver(phase1: phase1, ceremony: ceremony)
        }

        public func requestRelayOffer(_ request: Data) throws -> TOSPrivacyNative.RelayOffer {
            try replay.requestRelayOffer(request: request)
        }

        public func stagePaymentAndWipeSeed(
            seed: inout Data, prover: TOSPrivacyNative.PaymentProver,
            offer: TOSPrivacyNative.RelayOffer, request: Data
        ) throws -> TOSPrivacyNative.PaymentSubmission {
            try replay.stagePaymentAndWipeSeed(seed: &seed, prover: prover, offer: offer, request: request)
        }

        public func recoverPaymentAndWipeSeed(seed: inout Data, request: Data) throws -> TOSPrivacyNative.PaymentSubmission? {
            try replay.recoverPaymentAndWipeSeed(seed: &seed, request: request)
        }

        public func validateRecipient(_ descriptor: Data) throws -> Bool {
            try replay.validateRecipient(descriptor)
        }

        public func receiveAndWipeSeed(seed: inout Data, root: Data, binding: Data,
                                       requireCurrent: () throws -> Void) throws -> Data {
            defer { seed.resetBytes(in: 0..<seed.count) }
            return try replay.receiveAndWipeSeed(seed: &seed, root: root, binding: binding,
                                                requireCurrent: requireCurrent)
        }

        public func summaryAndWipeSeed(seed: inout Data, stopped: () -> Bool,
                                       recheck: () throws -> Void) throws -> Data {
            defer { seed.resetBytes(in: 0..<seed.count) }
            lock.lock(); defer { lock.unlock() }
            guard archive != nil, !stopped() else { throw Failure.stopped }
            try recheck()
            let result = try replay.summaryAndWipeSeed(seed: &seed, stopped: stopped)
            try recheck()
            guard !stopped() else { throw Failure.stopped }
            return result
        }
    }

    /// Blocking worker operation. Query returns ONLY a raw BOC; RPC metadata is ignored.
    /// A failure returns no ledger/archive and releases provisional native ownership.
    public static func replay(request: Data, query: (String, UInt64, Data) throws -> Data,
                              stopped: () -> Bool = { false }, recheck: () throws -> Void,
                              uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws -> Completed {
        let start = uptime()
        func running() throws {
            guard !stopped(), uptime() - start < 600 else { throw Failure.stopped }
        }
        try running(); try recheck()
        let replay = try TOSPrivacyNative.Replay(request: request)
        var succeeded = false
        defer { if !succeeded { replay.close() } }
        guard let object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
              let accountID = object["account_id"] as? String,
              let lt = object["last_lt"] as? String, var time = UInt64(lt),
              let initialHash = object["last_hash"] as? String,
              let root = object["account_root"] as? String,
              let clock = object["shard_time"] as? String, var maximumTime = UInt32(clock) else { throw Failure.malformed }
        let account = try word(accountID)
        var hash = try word(initialHash), state = try word(root)
        var newestFirst: [Data] = [], total = 0
        while time != 0 {
            try running()
            guard newestFirst.count < maximumTransactions else { throw Failure.limit }
            let received = try query("0:" + accountID, time, hash)
            try running()
            guard !received.isEmpty, received.count <= maximumTransactionBytes else { throw Failure.limit }
            let (size, overflow) = total.addingReportingOverflow(received.count)
            guard !overflow, size <= maximumArchiveBytes else { throw Failure.limit }
            // Own bytes independently of the untrusted fetcher before checking/staging them.
            let boc = try received.withUnsafeBytes { bytes -> Data in
                guard let base = bytes.baseAddress else { throw Failure.malformed }
                return Data(bytes: base, count: bytes.count)
            }
            let decoded = try TOSPrivacyNative.decodeHistoryTransaction(boc: boc, expectedHash: hash,
                logicalTime: time, accountID: account, postStateHash: state, maximumTime: maximumTime)
            guard let step = try JSONSerialization.jsonObject(with: decoded) as? [String: Any],
                  let previousLT = step["previous_lt"] as? String, let nextTime = UInt64(previousLT),
                  let previousHash = step["previous_hash"] as? String,
                  let oldState = step["pre_state_hash"] as? String,
                  let timestamp = step["time"] as? String, let nextMaximum = UInt32(timestamp) else { throw Failure.malformed }
            newestFirst.append(boc); total = size
            time = nextTime; hash = try word(previousHash); state = try word(oldState); maximumTime = nextMaximum
        }
        guard hash.allSatisfy({ $0 == 0 }) else { throw Failure.incomplete }
        let history = Array(newestFirst.reversed())
        for boc in history { try running(); try replay.push(boc: boc) }
        try running(); try replay.finish(); try recheck(); try running()
        let result = Completed(replay: replay, transactions: history)
        succeeded = true
        return result
    }

    private static func word(_ text: String) throws -> Data {
        guard text.utf8.count == 64, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.malformed }
        var result = Data()
        for offset in stride(from: 0, to: 64, by: 2) {
            let a = text.index(text.startIndex, offsetBy: offset)
            guard let byte = UInt8(text[a..<text.index(a, offsetBy: 2)], radix: 16) else { throw Failure.malformed }
            result.append(byte)
        }
        return result
    }
}
