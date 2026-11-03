import Foundation
import TOSShielded

/// Synchronous crypto over the TOS mnemonic master, before role-specific derivation.
/// The application must supply authenticated pool state and call off the UI thread.
public enum TOSPrivacyNative {
    public enum Failure: Error { case invalidInput, operationFailed }
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
