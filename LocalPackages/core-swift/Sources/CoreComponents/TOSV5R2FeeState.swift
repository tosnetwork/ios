import Foundation
import TOSFeeState
import TOSPQNative

public struct TOSV5R2FeeStateError: Error { public let status: Int32 }

/// Single-writer local state. The caller must authenticate route/time/counters and enrollment.
/// Preview and cached bytes do not authorize signing or broadcast.
public final class TOSV5R2FeeState {
    private struct FeeSecret { let seed: UnsafePointer<UInt8>?; let path: UnsafePointer<UInt8>? }
    private var handle: UInt64
    private let lock = NSLock()
    private init(handle: UInt64) { self.handle = handle }
    deinit { if handle != 0 { _ = tos_fee_state_close(handle) } }

    private static func check(_ status: Int32) throws {
        guard status == 0 else { throw TOSV5R2FeeStateError(status: status) }
    }
    private func session<T>(_ operation: (UInt64) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard handle != 0 else { throw TOSV5R2FeeStateError(status: -1) }
        return try operation(handle)
    }
    private static func pointer<T>(_ data: Data, _ body: (UnsafePointer<UInt8>?) throws -> T) rethrows -> T {
        try data.withUnsafeBytes { try body($0.bindMemory(to: UInt8.self).baseAddress) }
    }
    public static func open(directory: URL, globalID: Int32, network: Data, vault: Data,
                            treeID: Data, epoch0: UInt32, provenTime: UInt32) throws -> TOSV5R2FeeState {
        guard directory.isFileURL, network.count == 32, vault.count == 32, treeID.count == 32 else {
            throw TOSV5R2FeeStateError(status: -1)
        }
        let path = Data(directory.path.utf8)
        var output: UInt64 = 0
        let rc = pointer(path) { p in pointer(network) { n in pointer(vault) { v in pointer(treeID) { t in
            tos_fee_state_open(p, path.count, globalID, n, v, t, epoch0, provenTime, &output)
        }}}}
        try check(rc)
        return TOSV5R2FeeState(handle: output)
    }
    public func preview(time: UInt32, chainNext: UInt32) throws -> UInt32 {
        try session { h in
            var leaf = UInt32.max
            try Self.check(tos_fee_state_preview(h, time, chainNext, &leaf)); return leaf
        }
    }
    public func reserve(time: UInt32, chainNext: UInt32, leaf: UInt32, digest: Data) throws -> UInt64 {
        guard digest.count == 32 else { throw TOSV5R2FeeStateError(status: -1) }
        return try session { h in
            var token: UInt64 = 0
            let rc = Self.pointer(digest) { tos_fee_state_reserve(h, time, chainNext, leaf, $0, &token) }
            try Self.check(rc); return token
        }
    }
    public func close() throws {
        lock.lock(); defer { lock.unlock() }
        if handle == 0 { return }
        try Self.check(tos_fee_state_close(handle)); handle = 0
    }
    /// Consumes seed. Enrollment and current chain observations must be authenticated before this call.
    public func signOnceAndWipe(time: UInt32, chainNext: UInt32, leaf: UInt32, digest: Data,
                               publicKey: Data, seed: inout Data, path: Data) throws -> Data {
        defer { seed.resetBytes(in: 0..<seed.count) }
        guard seed.count == 48, path.count == 640, publicKey.count == 60, digest.count == 32 else {
            throw TOSV5R2FeeStateError(status: -1)
        }
        return try session { h in
            var output = Data(count: 2832)
            let rc = Self.pointer(seed) { s in Self.pointer(path) { p in Self.pointer(publicKey) { k in Self.pointer(digest) { d in
                var secret = FeeSecret(seed: s, path: p)
                return withUnsafeMutablePointer(to: &secret) { context in output.withUnsafeMutableBytes { out in
                    tos_fee_state_sign_once(h, time, chainNext, leaf, d, k, { opaque, key, q, hash, result, size in
                        guard let opaque else { return 0 }
                        let secret = opaque.assumingMemoryBound(to: FeeSecret.self).pointee
                        return tos_wallet_lms_fee_sign_reserved(secret.seed, 48, q, hash, 32,
                            secret.path, 640, key, 60, result, size)
                    }, { _, key, q, hash, sig, size in
                        tos_wallet_lms_fee_verify(q, hash, 32, sig, size, key, 60)
                    }, UnsafeMutableRawPointer(context), out.bindMemory(to: UInt8.self).baseAddress, 2832)
                }}
            }}}}
            try Self.check(rc); return output
        }
    }
    public func cacheVerified(token: UInt64, publicKey: Data, signature: Data) throws {
        guard publicKey.count == 60, signature.count == 2832 else { throw TOSV5R2FeeStateError(status: -1) }
        try session { h in
            let rc = Self.pointer(publicKey) { k in Self.pointer(signature) { s in
                tos_fee_state_cache_verified(h, token, k, s, signature.count, { _, key, leaf, digest, sig, size in
                    tos_wallet_lms_fee_verify(leaf, digest, 32, sig, size, key, 60)
                }, nil)
            }}
            try Self.check(rc)
        }
    }
    public func cachedVerified(leaf: UInt32, digest: Data, publicKey: Data) throws -> Data {
        guard publicKey.count == 60, digest.count == 32 else { throw TOSV5R2FeeStateError(status: -1) }
        return try session { h in
            var output = Data(count: 2832)
            let rc = Self.pointer(publicKey) { k in Self.pointer(digest) { d in output.withUnsafeMutableBytes { out in
                tos_fee_state_cached_verified(h, leaf, d, k, { _, key, q, hash, sig, size in
                    tos_wallet_lms_fee_verify(q, hash, 32, sig, size, key, 60)
                }, nil, out.bindMemory(to: UInt8.self).baseAddress, 2832)
            }}}
            try Self.check(rc); return output
        }
    }
}
