import Foundation
import TonSwift

/// Owned temporary input. String/UITextField copies are managed by the UI, not guaranteed erased by this buffer.
public final class TOSQuantumRecoveryInput {
    public var material: Data
    public var password: Data
    public var master = Data()
    public init(material: Data, password: Data) { self.material = material; self.password = password }
    public func derive(profile: TOSQuantumSeedKeychain.MasterProfile) throws {
        master.resetBytes(in: 0..<master.count)
        master.removeAll(keepingCapacity: false)
        defer { material.resetBytes(in: 0..<material.count); password.resetBytes(in: 0..<password.count) }
        if profile == .nativeMnemonic {
            guard let phrase = String(data: material, encoding: .utf8) else { throw TOSPQError.invalidInput }
            let words = phrase.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            master = try TOSQuantumMnemonic.masterAndWipePassword(words: words, password: &password)
        } else {
            guard material.count == 64, material.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }), password.isEmpty,
                  let text = String(data: material, encoding: .ascii) else { throw TOSPQError.invalidInput }
            master = Data(hex: text)
        }
    }
    public func wipe() {
        material.resetBytes(in: 0..<material.count); password.resetBytes(in: 0..<password.count); master.resetBytes(in: 0..<master.count)
    }
    deinit { wipe() }
}
