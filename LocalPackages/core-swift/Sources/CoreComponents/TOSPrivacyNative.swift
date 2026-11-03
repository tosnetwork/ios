import Foundation
import TOSShielded

/// Synchronous crypto over the TOS mnemonic master, before role-specific derivation.
/// The application must supply authenticated pool state and call off the UI thread.
public enum TOSPrivacyNative {
    public enum Failure: Error { case invalidInput, operationFailed, stateBinding, requiresWorker, stopped }
    public static let maxRequestBytes = 2 * 1024 * 1024
    public static let maxResponseBytes = 1024 * 1024
    private static let lock = NSLock()

    /// Durably reserve index before displaying this descriptor. Seed is consumed on all paths.
    public static func descriptorAndWipeSeed(seed: inout Data, domain: Data, index: UInt64) throws -> Data {
        defer { seed.resetBytes(in: 0..<seed.count) }
        guard seed.count == 32, domain.count == 32 else { throw Failure.invalidInput }
        lock.lock()
        defer { lock.unlock() }
        return try seed.withUnsafeBytes { key in
            try domain.withUnsafeBytes { context in
                let response = tos_shielded_descriptor(key.bindMemory(to: UInt8.self).baseAddress, 32,
                    context.bindMemory(to: UInt8.self).baseAddress, 32, index)
                return try copyAndRelease(response, exactSize: 2573)
            }
        }
    }

    /// Result contains private note material. Never log it; encrypt any retained copy.
    /// This batch result does not authenticate the chain or establish balance freshness.
    public static func scanAndWipeSeed(seed: inout Data, request: Data) throws -> Data {
        defer { seed.resetBytes(in: 0..<seed.count) }
        guard seed.count == 32, !request.isEmpty, request.count <= maxRequestBytes else {
            throw Failure.invalidInput
        }
        lock.lock()
        defer { lock.unlock() }
        return try seed.withUnsafeBytes { key in
            try request.withUnsafeBytes { input in
                let response = tos_shielded_scan(key.bindMemory(to: UInt8.self).baseAddress, 32,
                    input.bindMemory(to: UInt8.self).baseAddress, request.count)
                return try copyAndRelease(response)
            }
        }
    }

    /// Layout decoding only. expectedDataHash must come from an authenticated
    /// account proof; callers still verify address, code, network and profile pins.
    public static func decodePoolState(boc: Data, expectedDataHash: Data) throws -> Data {
        guard !boc.isEmpty, boc.count <= maxRequestBytes, expectedDataHash.count == 32 else {
            throw Failure.invalidInput
        }
        lock.lock()
        defer { lock.unlock() }
        let decoded = try boc.withUnsafeBytes { bytes in
            try copyAndRelease(tos_shielded_pool_state(bytes.bindMemory(to: UInt8.self).baseAddress, boc.count))
        }
        let object = try JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        let expected = expectedDataHash.map { String(format: "%02x", $0) }.joined()
        guard object?["data_hash"] as? String == expected else { throw Failure.stateBinding }
        return decoded
    }

    /// Expectations must originate in a verified account or the checked newer history link.
    /// One successful link does not establish history completeness or a private balance.
    public static func decodeHistoryTransaction(boc: Data, expectedHash: Data, logicalTime: UInt64,
                                                accountID: Data, postStateHash: Data, maximumTime: UInt32) throws -> Data {
        guard !boc.isEmpty, boc.count <= maxRequestBytes,
              [expectedHash, accountID, postStateHash].allSatisfy({ $0.count == 32 }), logicalTime > 0 else {
            throw Failure.invalidInput
        }
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        let request = try JSONSerialization.data(withJSONObject: ["version": 1,
            "boc": boc.base64EncodedString(), "expected_hash": hex(expectedHash),
            "expected_lt": String(logicalTime), "account_id": hex(accountID),
            "post_state_hash": hex(postStateHash), "maximum_time": String(maximumTime)])
        guard request.count <= maxRequestBytes else { throw Failure.invalidInput }
        lock.lock()
        defer { lock.unlock() }
        return try request.withUnsafeBytes { input in
            try copyAndRelease(tos_shielded_history_transaction(input.bindMemory(to: UInt8.self).baseAddress, request.count))
        }
    }

    /// Owned provisional replay. Use a verified same-checkpoint creation request.
    /// Free on cancellation; only successful finish enables reads. Call off the UI thread.
    public final class PaymentProver {
        fileprivate let handle: OpaquePointer

        fileprivate init(handle: OpaquePointer) { self.handle = handle }

        deinit { tos_shielded_payment_prover_free(handle) }
    }

    public final class Replay {
        private var handle: OpaquePointer?
        public init(request: Data) throws {
            guard !request.isEmpty, request.count <= TOSPrivacyNative.maxRequestBytes else { throw Failure.invalidInput }
            TOSPrivacyNative.lock.lock(); defer { TOSPrivacyNative.lock.unlock() }
            handle = request.withUnsafeBytes { input in
                tos_shielded_replay_create(input.bindMemory(to: UInt8.self).baseAddress, request.count)
            }
            guard handle != nil else { throw Failure.operationFailed }
        }
        deinit { close() }
        public func close() {
            TOSPrivacyNative.lock.lock(); defer { TOSPrivacyNative.lock.unlock() }
            if let handle { tos_shielded_replay_free(handle); self.handle = nil }
        }
        public func push(boc: Data) throws {
            TOSPrivacyNative.lock.lock(); defer { TOSPrivacyNative.lock.unlock() }
            guard let handle else { throw Failure.invalidInput }
            guard !boc.isEmpty, boc.count <= TOSPrivacyNative.maxRequestBytes else { discard(); throw Failure.invalidInput }
            let status = boc.withUnsafeBytes { input in
                tos_shielded_replay_push(handle, input.bindMemory(to: UInt8.self).baseAddress, boc.count)
            }
            guard status == 0 else { discard(); throw Failure.operationFailed }
        }
        public func finish() throws {
            TOSPrivacyNative.lock.lock(); defer { TOSPrivacyNative.lock.unlock() }
            guard let handle else { throw Failure.invalidInput }
            guard tos_shielded_replay_finish(handle) == 0 else { discard(); throw Failure.operationFailed }
        }
        public func loadPaymentProver(phase1: URL, ceremony: URL) throws -> PaymentProver {
            guard !Thread.isMainThread else { throw Failure.requiresWorker }
            guard phase1.isFileURL, ceremony.isFileURL else { throw Failure.invalidInput }
            let phase1Bytes = Array(phase1.path.utf8)
            let ceremonyBytes = Array(ceremony.path.utf8)
            TOSPrivacyNative.lock.lock(); defer { TOSPrivacyNative.lock.unlock() }
            guard let handle, tos_shielded_payment_supported() == 1 else { throw Failure.operationFailed }
            let prover = phase1Bytes.withUnsafeBufferPointer { phase1Path in
                ceremonyBytes.withUnsafeBufferPointer { ceremonyPath in
                    tos_shielded_payment_prover_load(
                        handle, phase1Path.baseAddress, phase1Path.count,
                        ceremonyPath.baseAddress, ceremonyPath.count
                    )
                }
            }
            guard let prover else { throw Failure.operationFailed }
            return PaymentProver(handle: prover)
        }

        public func validateRecipient(_ descriptor: Data) throws -> Bool {
            guard descriptor.count == 2573 else { return false }
            TOSPrivacyNative.lock.lock(); defer { TOSPrivacyNative.lock.unlock() }
            guard let handle else { throw Failure.invalidInput }
            return try descriptor.withUnsafeBytes { bytes in
                guard let result = tos_shielded_replay_validate_recipient(
                    handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) else {
                    throw Failure.operationFailed
                }
                defer { tos_shielded_response_free(result) }
                switch tos_shielded_response_status(result) {
                case 0: return true
                case 1: return false
                default: throw Failure.operationFailed
                }
            }
        }

        public func info() throws -> Data {
            TOSPrivacyNative.lock.lock(); defer { TOSPrivacyNative.lock.unlock() }
            guard let handle else { throw Failure.invalidInput }
            return try TOSPrivacyNative.copyAndRelease(tos_shielded_replay_info(handle))
        }
        public func scanAndWipeSeed(seed: inout Data, offset: Int, count: Int) throws -> Data {
            defer { seed.resetBytes(in: 0..<seed.count) }
            guard seed.count == 32, offset >= 0, count > 0, count <= 512 else { throw Failure.invalidInput }
            TOSPrivacyNative.lock.lock(); defer { TOSPrivacyNative.lock.unlock() }
            guard let handle else { throw Failure.invalidInput }
            return try seed.withUnsafeBytes { input in
                try TOSPrivacyNative.copyAndRelease(tos_shielded_replay_scan(handle, input.bindMemory(to: UInt8.self).baseAddress, 32, offset, count))
            }
        }
        /// Complete Ready-ledger summary with global note-body deduplication and
        /// spent reconciliation. No note secrets are returned. This synchronous
        /// operation requires a worker; cancellation is checked before/after the
        /// serialized native call, which cannot be interrupted while in progress.
        /// It neither authenticates freshness nor reserves the next receive index.
        public func summaryAndWipeSeed(seed: inout Data, stopped: () -> Bool) throws -> Data {
            defer { seed.resetBytes(in: 0..<seed.count) }
            guard seed.count == 32 else { throw Failure.invalidInput }
            guard !Thread.isMainThread else { throw Failure.requiresWorker }
            guard !stopped() else { throw Failure.stopped }
            TOSPrivacyNative.lock.lock(); defer { TOSPrivacyNative.lock.unlock() }
            guard let handle else { throw Failure.invalidInput }
            guard !stopped() else { throw Failure.stopped }
            let result = try seed.withUnsafeBytes { input in
                try TOSPrivacyNative.copyAndRelease(tos_shielded_replay_summary(
                    handle, input.bindMemory(to: UInt8.self).baseAddress, seed.count))
            }
            guard !stopped() else { throw Failure.stopped }
            return result
        }
        /// Issue a descriptor only after the native store commits its index.
        public func receiveAndWipeSeed(seed: inout Data, root: Data, binding: Data,
                                      requireCurrent: () throws -> Void) throws -> Data {
            defer { seed.resetBytes(in: 0..<seed.count) }
            guard seed.count == 32, (1...4096).contains(root.count), binding.count == 228 else {
                throw Failure.invalidInput
            }
            guard !Thread.isMainThread else { throw Failure.requiresWorker }
            try requireCurrent()
            TOSPrivacyNative.lock.lock(); defer { TOSPrivacyNative.lock.unlock() }
            guard let handle else { throw Failure.invalidInput }
            try requireCurrent()
            var result = try seed.withUnsafeBytes { key in
                try root.withUnsafeBytes { path in
                    try binding.withUnsafeBytes { pins in
                        try TOSPrivacyNative.copyAndRelease(tos_shielded_replay_receive(
                            handle, key.bindMemory(to: UInt8.self).baseAddress, key.count,
                            path.bindMemory(to: UInt8.self).baseAddress, path.count,
                            pins.bindMemory(to: UInt8.self).baseAddress, pins.count), exactSize: 2573)
                    }
                }
            }
            do { try requireCurrent() }
            catch {
                result.resetBytes(in: 0..<result.count)
                throw error
            }
            return result
        }

        // Caller already owns the shared native TOSPrivacyNative.lock.
        private func discard() {
            if let handle { tos_shielded_replay_free(handle); self.handle = nil }
        }
    }

    private static func copyAndRelease(_ response: OpaquePointer?, exactSize: Int? = nil) throws -> Data {
        guard let response else { throw Failure.operationFailed }
        defer { tos_shielded_response_free(response) }
        let size = tos_shielded_response_size(response)
        guard tos_shielded_response_status(response) == 0,
              size > 0, size <= maxResponseBytes,
              exactSize == nil || size == exactSize,
              let bytes = tos_shielded_response_data(response) else { throw Failure.operationFailed }
        return Data(bytes: bytes, count: size)
    }
}
