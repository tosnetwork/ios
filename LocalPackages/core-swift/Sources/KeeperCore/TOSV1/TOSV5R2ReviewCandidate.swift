import Foundation
import CryptoKit
import CoreFoundation
import TonSwift
import CoreComponents

/// Fixed unapproved development candidate. No deployment, readiness or wallet-default approval.
public enum TOSV5R2ReviewCandidate {
    public static let minimumVM = 18
    public static let globalID: Int32 = 1
    public static var network: Data { Data(repeating: 0x42, count: 32) }
    public static let configSHA256 = "3d480a6c3d9eed12b6ea687ab75f9d0a5fbcbbbad780a003af6c17a1ec6f72c7"
    public static func load() throws -> (codes: TOSV5R2Codes, pins: TOSV5R2CodePins) {
        func code(_ name: String, size: Int, sha: String, hash: String) throws -> Cell {
            guard let url = Bundle.module.url(forResource: name, withExtension: "boc", subdirectory: "V5R2ReviewCandidate") else { throw TOSPQError.invalidInput }
            let data = try Data(contentsOf: url)
            guard data.count == size, Data(SHA256.hash(data: data)) == Data(hex: sha) else { throw TOSPQError.keyBinding }
            let roots = try Cell.fromBoc(src: data)
            guard roots.count == 1, roots[0].hash() == Data(hex: hash) else { throw TOSPQError.keyBinding }
            return roots[0]
        }
        let wallet = try code("wallet", size: 3410, sha: "96ba6f8b91ad961e9c2fd62be9fb6e662ebf77cc2cf72eb6c276f96e738ce4ec", hash: "06203e98d4d8bf97b0cab37523ec435f5ab0e1d6d2c5253926eebf20ef1712f5")
        let module = try code("module", size: 3055, sha: "500dc4c115c636291a880c2d2874ab8c1c557dcaa5147421827b06824bba8475", hash: "f818dd311152d6ea13ef7f38002eb6f7390fac06bbe5df71bb8a2dd0c09c5b6d")
        let vault = try code("vault", size: 690, sha: "0a8dd10e6450a3e469e86572fc52b49bfc64e10fe2cd61071747f4ba4922e38e", hash: "9fa07637d49c4176766847251cfd820d5a11ade70fe92a45e11e419dba0452a0")
        return (TOSV5R2Codes(wallet: wallet, module: module, vault: vault), TOSV5R2CodePins(wallet: wallet.hash(), module: module.hash(), vault: vault.hash()))
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
