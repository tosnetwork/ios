import Foundation
import TOSPQNative

/// Derivation does not establish separate device custody or restore an LMS journal.
public enum TOSQuantumKdf {
    public enum Material: Int32 { case primary = 1, rescue = 2, fee = 3 }
    public static func deriveAndWipe(material: Material, master: inout Data, network: Data,
                                     globalID: Int32, account: UInt32, generation: UInt32,
                                     treeID: Data? = nil) throws -> Data {
        defer { master.resetBytes(in: 0..<master.count) }
        guard master.count == 32, network.count == 32,
              material == .fee ? treeID?.count == 32 : treeID == nil else {
            throw TOSPQError.invalidInput
        }
        let size = material == .primary ? 32 : 48
        let tree = treeID ?? Data()
        var output = Data(count: size)
        let rc = master.withUnsafeMutableBytes { m in network.withUnsafeBytes { n in tree.withUnsafeBytes { t in
            output.withUnsafeMutableBytes { out in
                tos_quantum_derive_and_wipe(material.rawValue, m.bindMemory(to: UInt8.self).baseAddress, 32,
                    n.bindMemory(to: UInt8.self).baseAddress, globalID, account, generation,
                    material == .fee ? t.bindMemory(to: UInt8.self).baseAddress : nil,
                    out.bindMemory(to: UInt8.self).baseAddress, size)
            }
        }}}
        guard rc == 0 else {
            output.resetBytes(in: 0..<output.count)
            throw TOSPQError.signingFailure
        }
        return output
    }
}
