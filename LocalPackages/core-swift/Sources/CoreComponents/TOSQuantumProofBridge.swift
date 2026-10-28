import Foundation
import CoreFoundation
import CryptoKit
import TOSProofVerify

/// Raw proof boundary; the caller must provision a trusted anchor and bind the proven wallet/configuration.
public enum TOSQuantumProofBridge {
    public struct Material {
        public let kind: UInt32
        public let bytes: Data
        public init(kind: UInt32, bytes: Data) { self.kind = kind; self.bytes = bytes }
    }
    public struct Result { public let verified: Data; public let nextState: Data }

    /// Native local execution with its checkpoint already durably committed.
    /// This payload is an estimate, never a verified receipt or balance update.
    public final class LocalSimulation {
        public let encoded: Data
        fileprivate init(_ encoded: Data, message: Data) throws {
            guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  object["interface"] as? String == "tos-self-pay-simulation/1",
                  object["scope"] as? String == "local_estimate",
                  let status = object["status"] as? String,
                  ["executed", "unsupported", "import_rejected", "not_accepted"].contains(status),
                  object["message_bytes_hash"] as? String == Data(SHA256.hash(data: message))
                    .map({ String(format: "%02x", $0) }).joined() else { throw TOSPQError.invalidInput }
            self.encoded = encoded
        }
    }
    public enum SimulationError: Error, Equatable { case native(Int32) }

    /// Integer storage is required: a rounded floating-point value must never
    /// become a history cursor, even when converting it to UInt64 would succeed.
    internal static func transactionLogicalTime(_ value: Any?) throws -> UInt64 {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), !(number is NSDecimalNumber),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
              let result = UInt64(number.stringValue) else { throw TOSPQError.invalidInput }
        return result
    }

    /// Decode only after binding to an authenticated account head/predecessor.
    /// Successful verification does not establish a completed payment.
    public static func verifyWalletTransaction(workchain: Int32, accountHash: Data, logicalTime: UInt64,
                                              expectedHash: Data, boc: Data) throws -> Data {
        guard workchain == 0, accountHash.count == 32, expectedHash.count == 32, logicalTime > 0,
              (1...1_048_576).contains(boc.count) else { throw TOSPQError.invalidInput }
        // Separate arrays also satisfy the native ABI's disjoint borrowed ranges
        // when a caller passes Data values sharing the same storage.
        let account = [UInt8](accountHash), hash = [UInt8](expectedHash), bytes = [UInt8](boc)
        var output = Data(count: 1_048_576), used = 0
        let status = account.withUnsafeBufferPointer { a in hash.withUnsafeBufferPointer { h in
            bytes.withUnsafeBufferPointer { b in output.withUnsafeMutableBytes { result in
                tos_proof_verify_wallet_transaction(workchain, a.baseAddress, logicalTime, h.baseAddress,
                    b.baseAddress, b.count, result.bindMemory(to: CChar.self).baseAddress, result.count, &used)
            } }
        } }
        guard status == 0, used > 0, used <= output.count else { throw TOSPQError.invalidInput }
        return Data(output.prefix(used))
    }
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

    internal static func simulatePersisted(directory: URL, anchor: Data, request: Data, now: Int64,
                                           signedMessage: Data, transport: @escaping Transport) throws -> LocalSimulation {
        guard now > 0, now <= Int64(UInt32.max),
              (1...1_048_576).contains(anchor.count), (1...1_048_576).contains(request.count),
              (1...1_048_576).contains(signedMessage.count), !directory.path.utf8.contains(0) else {
            throw TOSPQError.invalidInput
        }
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
        // Separate message storage keeps all borrowed C ABI input ranges disjoint.
        let message = [UInt8](signedMessage), anchorBytes = [UInt8](anchor), requestBytes = [UInt8](request)
        var output = Data(count: 2_097_152), used = 0
        let status = withExtendedLifetime(context) {
            directory.path.withCString { path in anchorBytes.withUnsafeBufferPointer { a in requestBytes.withUnsafeBufferPointer { r in
                message.withUnsafeBufferPointer { m in output.withUnsafeMutableBytes { out in
                    tos_proof_acquire_simulate_self_pay_persisted(path,
                        a.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, a.count,
                        r.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, r.count, now, callback, opaque,
                        m.baseAddress, m.count, out.bindMemory(to: CChar.self).baseAddress, out.count, &used)
                } }
            } } }
        }
        if let failure = context.failure { throw failure }
        guard status == 0 else { throw SimulationError.native(status) }
        guard used > 0, used <= output.count else { throw TOSPQError.invalidInput }
        return try LocalSimulation(Data(output.prefix(used)), message: signedMessage)
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
        /// Authenticated raw state, or nil for proven absence. No deployment/signing eligibility is implied.
        public func provenAccountState(expectedAddress: String) throws -> Data? {
            let account = try boundAccount(expectedAddress)
            guard let exists = account["exists"] as? Bool else { throw TOSPQError.invalidInput }
            if !exists { return nil }
            guard let encoded = account["state_boc"] as? String, let bytes = Data(base64Encoded: encoded),
                  !bytes.isEmpty else { throw TOSPQError.invalidInput }
            return bytes
        }
        public func provenAccountTime(expectedAddress: String) throws -> UInt32 {
            let account = try boundAccount(expectedAddress)
            guard let time = account["gen_utime"] as? Int64, time >= 0, time <= Int64(UInt32.max) else {
                throw TOSPQError.invalidInput
            }
            return UInt32(time)
        }
        /// Authenticated ShardAccount transaction head. RPC transaction metadata
        /// is not an anchor; callers must hash-check each raw transaction and
        /// follow its committed previous hash/lt, with a bounded walk.
        public func provenTransactionHead(expectedAddress: String) throws -> (logicalTime: UInt64, hash: Data) {
            let account = try boundAccount(expectedAddress)
            let logicalTime = try TOSQuantumProofBridge.transactionLogicalTime(account["last_trans_lt"])
            guard let encoded = account["last_trans_hash"] as? String, encoded.utf8.count == 64,
                  encoded.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw TOSPQError.invalidInput
            }
            var hash = Data()
            for offset in stride(from: 0, to: encoded.count, by: 2) {
                let start = encoded.index(encoded.startIndex, offsetBy: offset)
                let end = encoded.index(start, offsetBy: 2)
                guard let byte = UInt8(encoded[start..<end], radix: 16) else { throw TOSPQError.invalidInput }
                hash.append(byte)
            }
            guard (logicalTime == 0) == hash.allSatisfy({ $0 == 0 }) else { throw TOSPQError.invalidInput }
            return (logicalTime, hash)
        }
        private func boundAccount(_ address: String) throws -> [String: Any] {
            guard address.range(of: "^0:[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let account = value["account"] as? [String: Any], account["address"] as? String == address else {
                throw TOSPQError.keyBinding
            }
            return account
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
        public func requestAtCheckpoint(account: String? = nil, configIndices: [Int] = [], maximumAge: Int64) throws -> Data {
            guard (1...604800).contains(maximumAge), configIndices.count <= 64,
                  configIndices.allSatisfy({ $0 >= 0 && $0 <= Int(Int32.max) }), Set(configIndices).count == configIndices.count,
                  account != nil || !configIndices.isEmpty,
                  account == nil || account!.range(of: "^0:[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let target = value["target"] as? [String: Any] else { throw TOSPQError.invalidInput }
            var exact: [String: Any] = [:]
            for field in ["workchain", "shard", "seqno", "root_hash", "file_hash"] {
                guard let entry = target[field] else { throw TOSPQError.invalidInput }
                exact[field] = entry
            }
            var request: [String: Any] = ["mode": "live", "target": exact, "max_age_seconds": maximumAge]
            if let account { request["account"] = account }
            if !configIndices.isEmpty { request["config_params"] = configIndices }
            return try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        }
        public func masterchainTime() throws -> UInt32 {
            guard let target = value["target"] as? [String: Any], let time = target["gen_utime"] as? Int64,
                  time >= 0, time <= Int64(UInt32.max) else { throw TOSPQError.invalidInput }
            return UInt32(time)
        }
        public func accountTime(expectedAddress: String, expectedCodeHash: Data) throws -> UInt32 {
            _ = try accountState(expectedAddress: expectedAddress, expectedCodeHash: expectedCodeHash)
            guard let account = value["account"] as? [String: Any], let time = account["gen_utime"] as? Int64,
                  time >= 0, time <= Int64(UInt32.max) else { throw TOSPQError.invalidInput }
            return UInt32(time)
        }
        /// Authenticated dynamic chain state; schema and policy checks remain mandatory.
        public func provenConfigParam(_ index: Int) throws -> Data {
            guard index >= 0, let params = value["config_params"] as? [[String: Any]] else { throw TOSPQError.keyBinding }
            let matches = params.filter { $0["index"] as? Int == index }
            guard matches.count == 1, let encoded = matches[0]["boc"] as? String,
                  let bytes = Data(base64Encoded: encoded), !bytes.isEmpty else { throw TOSPQError.keyBinding }
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
