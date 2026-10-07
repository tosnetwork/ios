import Foundation
import TonSwift
import CoreComponents

/// Initial public identities only. This never establishes current authority or fee continuity.
public struct TOSV5R2InitialRecovery {
    public enum SeedProfile: String, Decodable { case nativeMnemonic = "tos-native-mnemonic-v1", rawMaster32 = "raw-master-32-v1" }
    public struct Derivation: Decodable {
        public let account_index: UInt32, key_generation: UInt32
        public let primary_seed_profile: SeedProfile, rescue_seed_profile: SeedProfile, fee_seed_profile: SeedProfile
    }
    public let genesis: TOSV5R2Genesis
    public let derivation: Derivation
    public let lastObservedEpoch: UInt64?
    private struct Wire: Decodable {
        let schema: String, kdf: String, derivation: Derivation, workchain: Int32, global_id: Int32
        let network: String, wallet_id: UInt32, primary_key: String, rescue_key: String, policy: String
        let fee_profile: String, fee_tree_id: String, fee_public_key: String, fee_epoch0: UInt32
        let wallet_code: String, module_code: String, vault_code: String
        let wallet_state_init: String, module_state_init: String, vault_state_init: String, fee_config_hash: String
        let last_observed_epoch: UInt64?
    }
    private static let fields: Set<String> = ["schema", "kdf", "derivation", "workchain", "global_id", "network", "wallet_id",
        "primary_key", "rescue_key", "policy", "fee_profile", "fee_tree_id", "fee_public_key", "fee_epoch0", "wallet_code",
        "module_code", "vault_code", "wallet_state_init", "module_state_init", "vault_state_init", "fee_config_hash", "last_observed_epoch"]
    private static let derivationFields: Set<String> = ["account_index", "key_generation", "primary_seed_profile", "rescue_seed_profile", "fee_seed_profile"]

    /// Pins and expected wallet are independently trusted inputs, never read from the manifest itself.
    public static func parseAndReconstruct(_ encoded: Data, codes: TOSV5R2Codes, pins: TOSV5R2CodePins,
                                          expectedWallet: Address) throws -> TOSV5R2InitialRecovery {
        guard encoded.count <= 16 * 1024, expectedWallet.workchain == 0,
              let text = String(data: encoded, encoding: .utf8) else { throw TOSPQError.invalidInput }
        let wire: Wire
        do { try checkStructure(text); wire = try JSONDecoder().decode(Wire.self, from: encoded) }
        catch { throw TOSPQError.invalidInput } // Never propagate input-bearing parser diagnostics.
        guard wire.schema == "TOS-WALLET-V5R2-INITIAL-RECOVERY-v1", wire.kdf == "TOS-WALLET-DUALROOT-KDF-v1",
              wire.workchain == 0, wire.fee_profile == "HSS-L1-LMS-SHA256-M32-H20-LMOTS-SHA256-N32-W4" else { throw TOSPQError.invalidInput }
        guard try bytes(wire.wallet_code, 32) == pins.wallet, try bytes(wire.module_code, 32) == pins.module,
              try bytes(wire.vault_code, 32) == pins.vault else { throw TOSPQError.keyBinding }
        let policy: TOSV5R2Policy
        switch wire.policy { case "RESCUE_READY": policy = .ready; case "SLH_REQUIRED": policy = .required
        default: throw TOSPQError.invalidInput }
        let genesis = try TOSV5R2Genesis(codes: codes, pins: pins, globalId: wire.global_id,
            network: bytes(wire.network, 32), walletId: wire.wallet_id, primaryKey: bytes(wire.primary_key, 1312),
            rescueKey: bytes(wire.rescue_key, 32), policy: policy, feeTreeId: bytes(wire.fee_tree_id, 32),
            feePublicKey: bytes(wire.fee_public_key, 60), epoch0: wire.fee_epoch0)
        guard genesis.address == expectedWallet else { throw TOSPQError.keyBinding }
        guard try bytes(wire.wallet_state_init, 32) == genesis.walletInit.hash(),
              try bytes(wire.module_state_init, 32) == genesis.moduleInit.hash(),
              try bytes(wire.vault_state_init, 32) == genesis.vaultInit.hash(),
              try bytes(wire.fee_config_hash, 32) == genesis.configHash else { throw TOSPQError.keyBinding }
        return TOSV5R2InitialRecovery(genesis: genesis, derivation: wire.derivation, lastObservedEpoch: wire.last_observed_epoch)
    }
    private static func bytes(_ text: String, _ size: Int) throws -> Data {
        guard text.utf8.count == size * 2, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw TOSPQError.invalidInput }
        return Data(hex: text)
    }
    // Bound depth before decoding; reject duplicate decoded keys and unknown fields.
    private static func checkStructure(_ text: String) throws {
        let data = Array(text.utf8)
        var scopes = [Set<String>]()
        var start: Int?; var escaped = false; var i = 0
        while i < data.count {
            let c = data[i]
            if let begin = start {
                if escaped { escaped = false }
                else if c == 92 { escaped = true }
                else if c == 34 {
                    var next = i + 1
                    while next < data.count && [9, 10, 13, 32].contains(data[next]) { next += 1 }
                    if next < data.count && data[next] == 58 {
                        guard !scopes.isEmpty else { throw TOSPQError.invalidInput }
                        let key = try JSONDecoder().decode(String.self, from: Data(data[begin...i]))
                        let allowed = scopes.count == 1 ? fields : derivationFields
                        guard allowed.contains(key), scopes[scopes.count - 1].insert(key).inserted else { throw TOSPQError.invalidInput }
                    }
                    start = nil
                }
            } else {
                switch c {
                case 34: start = i
                case 123: guard scopes.count < 2 else { throw TOSPQError.invalidInput }; scopes.append([])
                case 125: guard !scopes.isEmpty else { throw TOSPQError.invalidInput }; scopes.removeLast()
                case 91, 93: throw TOSPQError.invalidInput
                case 45, 48...57:
                    var end = i + 1
                    while end < data.count && ![9, 10, 13, 32, 44, 125].contains(data[end]) { end += 1 }
                    let token = String(decoding: data[i..<end], as: UTF8.self)
                    guard token.range(of: "^-?(0|[1-9][0-9]*)$", options: .regularExpression) != nil else { throw TOSPQError.invalidInput }
                    i = end - 1
                default: break
                }
            }
            i += 1
        }
        guard start == nil, scopes.isEmpty else { throw TOSPQError.invalidInput }
    }
}
