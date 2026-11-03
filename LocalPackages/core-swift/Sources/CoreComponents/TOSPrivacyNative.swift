import Foundation
import TOSShielded

/// Synchronous crypto over the TOS mnemonic master, before role-specific derivation.
/// The application must supply authenticated pool state and call off the UI thread.
public enum TOSPrivacyNative {
    public enum Failure: Error { case invalidInput, operationFailed, stateBinding }
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
