import Foundation
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
              material.allSatisfy({ (1...7).contains($0.kind) && !$0.bytes.isEmpty }),
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
}
