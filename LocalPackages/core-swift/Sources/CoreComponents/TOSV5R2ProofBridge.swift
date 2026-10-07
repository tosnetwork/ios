import Foundation
import CryptoKit
import TOSProofVerify

/// Raw proof boundary; the caller must provision a trusted anchor and bind the proven wallet/configuration.
public enum TOSV5R2ProofBridge {
    public struct Material {
        public let kind: UInt32
        public let bytes: Data
        public init(kind: UInt32, bytes: Data) { self.kind = kind; self.bytes = bytes }
    }
    public struct Result { public let verified: Data; public let nextState: Data }
    public static func verify(anchor: Data, request: Data, state: Data, now: Int64, material: [Material]) throws -> Result {
        guard now > 0, (1...1_048_576).contains(anchor.count), (1...1_048_576).contains(request.count),
              state.count <= 1_048_576, material.count <= 1045,
              material.allSatisfy({ (1...7).contains($0.kind) && (1...67_108_864).contains($0.bytes.count) }),
              material.reduce(Int64(0), { $0 + Int64($1.bytes.count) }) <= 67_108_864 else { throw TOSPQError.invalidInput }
        let buffers = material.map { value -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: value.bytes.count)
            value.bytes.copyBytes(to: pointer, count: value.bytes.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let descriptors = zip(material, buffers).map { value, pointer in
            tos_proof_material(kind: value.kind, data: UnsafePointer(pointer), size: value.bytes.count)
        }
        var output = Data(count: 67_108_864), next = Data(count: 1_048_576)
        var used = 0, nextUsed = 0
        let status = anchor.withUnsafeBytes { a in request.withUnsafeBytes { r in state.withUnsafeBytes { s in
            descriptors.withUnsafeBufferPointer { parts in output.withUnsafeMutableBytes { out in next.withUnsafeMutableBytes { n in
                tos_proof_verify_embedded(a.bindMemory(to: CChar.self).baseAddress, a.count,
                    r.bindMemory(to: CChar.self).baseAddress, r.count, s.bindMemory(to: CChar.self).baseAddress, s.count,
                    now, parts.baseAddress, parts.count, out.bindMemory(to: CChar.self).baseAddress, out.count, &used,
                    n.bindMemory(to: CChar.self).baseAddress, n.count, &nextUsed)
            } } }
        } } }
        guard status == 0, used > 0, used <= output.count, nextUsed <= next.count else { throw TOSPQError.invalidInput }
        return Result(verified: Data(output.prefix(used)), nextState: Data(next.prefix(nextUsed)))
    }
    internal static func verifyPersisted(directory: URL, initialize: Bool, anchor: Data, request: Data, now: Int64, material: [Material]) throws -> Data {
        guard now > 0, (1...1_048_576).contains(anchor.count), (1...1_048_576).contains(request.count),
              material.count <= 1045, material.allSatisfy({ (1...7).contains($0.kind) && (1...67_108_864).contains($0.bytes.count) }),
              material.reduce(Int64(0), { $0 + Int64($1.bytes.count) }) <= 67_108_864 else { throw TOSPQError.invalidInput }
        let buffers = material.map { value -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: value.bytes.count)
            value.bytes.copyBytes(to: pointer, count: value.bytes.count); return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let descriptors = zip(material, buffers).map { value, pointer in
            tos_proof_material(kind: value.kind, data: UnsafePointer(pointer), size: value.bytes.count)
        }
        var output = Data(count: 67_108_864), used = 0
        let status = directory.path.withCString { path in anchor.withUnsafeBytes { a in request.withUnsafeBytes { r in
            descriptors.withUnsafeBufferPointer { parts in output.withUnsafeMutableBytes { out in
                tos_proof_verify_live_persisted(path, initialize ? 1 : 0, a.bindMemory(to: CChar.self).baseAddress, a.count,
                    r.bindMemory(to: CChar.self).baseAddress, r.count, now, parts.baseAddress, parts.count,
                    out.bindMemory(to: CChar.self).baseAddress, out.count, &used)
            } }
        } } }
        guard status == 0, used > 0, used <= output.count else { throw TOSPQError.invalidInput }
        return Data(output.prefix(used))
    }

    /// Blocking transport; callers must enforce bounded receive, timeout and cancellation.
    public typealias Transport = (Data, Int) throws -> Data
    private final class QueryContext {
        let transport: Transport
        var failure: Error?
        init(_ transport: @escaping Transport) { self.transport = transport }
    }
    internal static func acquirePersisted(directory: URL, initialize: Bool, anchor: Data, request: Data,
                                          now: Int64, transport: @escaping Transport) throws -> Data {
        guard now > 0, (1...1_048_576).contains(anchor.count), (1...1_048_576).contains(request.count),
              !directory.path.utf8.contains(0) else { throw TOSPQError.invalidInput }
        let context = QueryContext(transport)
        let opaque = Unmanaged.passUnretained(context).toOpaque()
        let callback: tos_proof_query_callback = { opaque, query, querySize, response, capacity, used in
            guard let opaque, let query, let response, let used,
                  (1...16384).contains(querySize), (1...67_108_864).contains(capacity) else { return -1 }
            used.pointee = 0
            let context = Unmanaged<QueryContext>.fromOpaque(opaque).takeUnretainedValue()
            do {
                let bytes = try context.transport(Data(bytes: query, count: querySize), capacity)
                guard !bytes.isEmpty, bytes.count <= capacity else { throw TOSPQError.invalidInput }
                bytes.copyBytes(to: response, count: bytes.count)
                used.pointee = bytes.count
                return 0
            } catch {
                context.failure = error
                return -1
            }
        }
        var output = Data(count: 67_108_864), used = 0
        let status = withExtendedLifetime(context) {
            directory.path.withCString { path in anchor.withUnsafeBytes { a in request.withUnsafeBytes { r in
                output.withUnsafeMutableBytes { out in
                    tos_proof_acquire_verify_live_persisted(path, initialize ? 1 : 0,
                        a.bindMemory(to: CChar.self).baseAddress, a.count,
                        r.bindMemory(to: CChar.self).baseAddress, r.count, now, callback, opaque,
                        out.bindMemory(to: CChar.self).baseAddress, out.count, &used)
                }
            } } }
        }
        if let failure = context.failure { throw failure }
        guard status == 0, used > 0, used <= output.count else { throw TOSPQError.invalidInput }
        return Data(output.prefix(used))
    }

    /// A capability produced only by native verification. Binding alone does not authorize signing.
    public final class BoundRead {
        private let value: [String: Any]
        private let anchorDigest: Data
        private let checkpoint: Data
        fileprivate init(verified: Data, request: Data, anchor: Data) throws {
            guard let object = try JSONSerialization.jsonObject(with: verified) as? [String: Any],
                  object["status"] as? String == "verified", object["interface"] as? String == "tos-proof-verify/1",
                  object["request_sha256"] as? String == Self.hex(Data(SHA256.hash(data: request))),
                  let target = object["target"] as? [String: Any] else { throw TOSPQError.invalidInput }
            value = object
            anchorDigest = Data(SHA256.hash(data: anchor))
            checkpoint = try JSONSerialization.data(withJSONObject: target, options: [.sortedKeys])
        }
        private static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        /// Repeat at authorization using the local clock and configured age limit.
        public func requireLive(now: Int64, maximumAge: Int64) throws {
            guard now > 0, (1...604800).contains(maximumAge), value["mode"] as? String == "live",
                  let live = value["live"] as? [String: Any], let verifiedNow = live["now"] as? Int64,
                  let nativeLimit = live["max_age_seconds"] as? Int64,
                  let target = value["target"] as? [String: Any], let timestamp = target["gen_utime"] as? Int64,
                  now >= verifiedNow, maximumAge <= nativeLimit,
                  (-60...maximumAge).contains(now - timestamp) else { throw TOSPQError.invalidInput }
        }
        public func requireSameCheckpoint(_ other: BoundRead) throws {
            guard anchorDigest == other.anchorDigest, checkpoint == other.checkpoint else { throw TOSPQError.keyBinding }
        }
        public func accountState(expectedAddress: String, expectedCodeHash: Data) throws -> Data {
            guard expectedAddress.range(of: "^-?[0-9]+:[0-9a-f]{64}$", options: .regularExpression) != nil,
                  expectedCodeHash.count == 32, let account = value["account"] as? [String: Any],
                  account["exists"] as? Bool == true, account["active"] as? Bool == true,
                  account["address"] as? String == expectedAddress,
                  account["code_hash"] as? String == Self.hex(expectedCodeHash),
                  let encoded = account["state_boc"] as? String, let bytes = Data(base64Encoded: encoded),
                  !bytes.isEmpty else { throw TOSPQError.keyBinding }
            return bytes
        }
        public func configParam(_ index: Int, expectedCellHash: Data) throws -> Data {
            guard index >= 0, expectedCellHash.count == 32,
                  let params = value["config_params"] as? [[String: Any]] else { throw TOSPQError.keyBinding }
            let matches = params.filter { $0["index"] as? Int == index }
            guard matches.count == 1, matches[0]["cell_hash"] as? String == Self.hex(expectedCellHash),
                  let encoded = matches[0]["boc"] as? String, let bytes = Data(base64Encoded: encoded),
                  !bytes.isEmpty else { throw TOSPQError.keyBinding }
            return bytes
        }
    }
    public static func verifyHistoricalBound(anchor: Data, request: Data, now: Int64, material: [Material]) throws -> BoundRead {
        guard (1...1_048_576).contains(request.count),
              let object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
              object["mode"] as? String == "historical" else { throw TOSPQError.invalidInput }
        let result = try verify(anchor: anchor, request: request, state: Data(), now: now, material: material)
        return try BoundRead(verified: result.verified, request: request, anchor: anchor)
    }
    internal static func acquireBound(directory: URL, initialize: Bool, anchor: Data, request: Data,
                                      now: Int64, transport: @escaping Transport) throws -> BoundRead {
        let result = try acquirePersisted(directory: directory, initialize: initialize, anchor: anchor, request: request, now: now, transport: transport)
        return try BoundRead(verified: result, request: request, anchor: anchor)
    }

}
