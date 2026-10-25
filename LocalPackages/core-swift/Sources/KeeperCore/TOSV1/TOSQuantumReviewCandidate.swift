import Foundation
import CryptoKit
import CoreFoundation
import TonSwift
import CoreComponents

/// Fixed unapproved development candidate. No deployment, readiness or wallet-default approval.
public enum TOSQuantumReviewCandidate {
    public static let minimumVM = 16
    public static let globalID: Int32 = 1
    public static var network: Data { Data(repeating: 0x42, count: 32) }
    public static let configSHA256 = "59880ee43f99c6e103bb60a99af4696bbadaff0dc7c064c04b438cc0a904d800"
    public static func load() throws -> (codes: TOSQuantumCodes, pins: TOSQuantumCodePins) {
        func code(_ name: String, size: Int, sha: String, hash: String) throws -> Cell {
            guard let url = Bundle.module.url(forResource: name, withExtension: "boc", subdirectory: "QuantumReviewCandidate") else { throw TOSPQError.invalidInput }
            let data = try Data(contentsOf: url)
            guard data.count == size, Data(SHA256.hash(data: data)) == Data(hex: sha) else { throw TOSPQError.keyBinding }
            let roots = try Cell.fromBoc(src: data)
            guard roots.count == 1, roots[0].hash() == Data(hex: hash) else { throw TOSPQError.keyBinding }
            return roots[0]
        }
        let wallet = try code("wallet", size: 3446, sha: "ca804d2c2162b79ec47691da2889e991b6001c90336226f37967a3aca6ca3089", hash: "18252490f90f12149832b6067ca60f3f0216f23a97d71e7afcd8017eeb75e61f")
        let module = try code("module", size: 3055, sha: "500dc4c115c636291a880c2d2874ab8c1c557dcaa5147421827b06824bba8475", hash: "f818dd311152d6ea13ef7f38002eb6f7390fac06bbe5df71bb8a2dd0c09c5b6d")
        let vault = try code("vault", size: 690, sha: "0a8dd10e6450a3e469e86572fc52b49bfc64e10fe2cd61071747f4ba4922e38e", hash: "9fa07637d49c4176766847251cfd820d5a11ade70fe92a45e11e419dba0452a0")
        return (TOSQuantumCodes(wallet: wallet, module: module, vault: vault), TOSQuantumCodePins(wallet: wallet.hash(), module: module.hash(), vault: vault.hash()))
    }
    public static func requireChain(manifest: Data) throws {
        guard manifest.count <= 16 * 1024,
              let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let networkText = object["network"] as? String, let global = object["global_id"] as? NSNumber,
              CFGetTypeID(global) != CFBooleanGetTypeID(),
              !["d", "f"].contains(String(cString: global.objCType)),
              networkText == String(repeating: "42", count: 32), global.int64Value == Int64(globalID) else { throw TOSPQError.keyBinding }
    }
}
