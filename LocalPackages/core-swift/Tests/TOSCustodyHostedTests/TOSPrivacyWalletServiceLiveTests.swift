import CoreComponents
import Foundation
import TKKeychain
import TonSwift
@testable import KeeperCore
import XCTest

/// Requires the existing WalletCoreHosted application test host and a dedicated
/// simulator. Uses a unique vault namespace, not the user's records or PIN.
final class TOSPrivacyWalletServiceLiveTests: XCTestCase {
    func testOriginalMnemonicCustodyThroughUserReadService() async throws {
        guard let encoded = ProcessInfo.processInfo.environment["TOS_PRIVACY_LIVE_CONFIG"], !encoded.isEmpty else {
            throw XCTSkip("Set TOS_PRIVACY_LIVE_CONFIG to the isolated live-pool configuration")
        }
        let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
        guard bytes.count <= 131_072 else { throw TOSPQError.invalidInput }
        try await Task.detached {
            let config = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            func string(_ name: String) throws -> String { try XCTUnwrap(config[name] as? String) }
            func hash(_ name: String) throws -> Data {
                let text = try string(name)
                guard text.count == 64, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw TOSPQError.invalidInput
                }
                let chars = Array(text.utf8)
                func nibble(_ b: UInt8) -> UInt8 { b <= 57 ? b - 48 : b - 87 }
                return Data(stride(from: 0, to: 64, by: 2).map { nibble(chars[$0]) << 4 | nibble(chars[$0 + 1]) })
            }
            let url = try XCTUnwrap(URL(string: string("rpc")))
            guard url.scheme == "http", url.host == "127.0.0.1" else { throw TOSPQError.invalidInput }
            let profile = try TOSQuantumNetworkProfile(globalID: 3, rootHash: string("root_hash"), fileHash: string("file_hash"))
            let words = Array(repeating: "abandon", count: 11) + ["amateur"] // Public native vector.
            let mnemonic = try CoreComponents.Mnemonic(mnemonicWords: words)
            var phrasePassword = Data()
            var master = try TOSQuantumMnemonic.masterAndWipePassword(words: words, password: &phrasePassword)
            defer { master.resetBytes(in: 0..<master.count) }
            let namespace = Data(repeating: 5, count: 32)
            func publicKey(_ role: TOSQuantumRole, material: TOSQuantumKdf.Material) throws -> Data {
                var copy = master
                var seed = try TOSQuantumKdf.deriveAndWipe(material: material, master: &copy,
                    network: namespace, globalID: 3, account: 0, generation: 0)
                defer { seed.resetBytes(in: 0..<seed.count) }
                return try TOSQuantumSigner.publicKey(role: role, seed: seed)
            }
            let identity = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority:
                TOSQuantumSelfPayAuthority(globalID: 3, namespace: namespace,
                    primaryKey: publicKey(.primary, material: .primary), rescueKey: publicKey(.rescue, material: .rescue))))
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: base) }
            let id = UUID()
            let wallet = Wallet(id: id.uuidString,
                identity: WalletIdentity(network: .mainnet, kind: .Quantum(identity), networkGlobalId: 3),
                metaData: WalletMetaData(label: "Isolated privacy read test", tintColor: .defaultColor, icon: .icon(.wallet)),
                setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
            let relay = try TOSQuantumProofHTTPTransport(endpoint: url)
            let transport: TOSQuantumProofBridge.Transport = { try relay.query($0, maximumBytes: $1) }
            func now() -> Int64 { Int64(Date().timeIntervalSince1970) }
            let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: profile.anchor(), baseDirectory: base)
            _ = try session.enrollBound(request: JSONSerialization.data(withJSONObject:
                ["mode": "live", "max_age_seconds": 300, "config_params": [19, 21]]), now: now(), transport: transport)
            try TOSQuantumCreationRecord(id: id, profile: profile, identity: identity).save(baseDirectory: base)
            let selection = try TOSPrivacyPoolSelection(profile: profile,
                address: Address(workchain: 0, hash: hash("pool_account")),
                codeBOC: XCTUnwrap(Data(base64Encoded: string("code_boc"))), profileHash: hash("profile_hash"),
                manifestHash: hash("poseidon_manifest_hash"), verifyingKeyHash: hash("groth16_vk_hash"),
                sourceDescription: "Explicit existing isolated test deployment")
            let previousEndpoint = TOSRPCSettings.customEndpoint
            defer {
                if let previousEndpoint { _ = try? TOSRPCSettings.setCustomEndpoint(previousEndpoint) }
                else { TOSRPCSettings.reset() }
            }
            try TOSRPCSettings.setCustomEndpoint(url.absoluteString)
            let namespaceID = "privacy-read-test-" + UUID().uuidString
            let vault = MnemonicsVault(keychainVault: TKKeychainVaultImplementation(keychain: TKKeychainImplementation()),
                seedProvider: { namespaceID })
            var stage = "save isolated encrypted mnemonic"
            func diagnostic(_ error: Error) -> String {
                if case TKKeychainError.other(let status) = error { return "Keychain OSStatus \(status)" }
                return String(reflecting: type(of: error))
            }
            do {
                let password = "public isolated test password"
                try await vault.saveMnemonic(mnemonic, wallet: wallet, password: password)
                stage = "prepare original wallet"
                let service = TOSPrivacyWalletService(mnemonics: vault, baseDirectory: base,
                    outboxDirectory: base.appendingPathComponent("outbox"), privacyStoreParent: base, now: now)
                let preparation = try await service.prepare(wallet: wallet)
                XCTAssertEqual(preparation.profile, profile)
                XCTAssertEqual(preparation.access, .appPasscode)
                stage = "refuse incorrect custody route"
                do {
                    _ = try await service.read(wallet: wallet, authorization: .devicePresence, selection: selection)
                    XCTFail("Device presence must never replace ordinary vault authorization")
                } catch TOSPrivacyWalletService.Failure.binding { }
                stage = "refuse incorrect vault password"
                do {
                    _ = try await service.read(wallet: wallet, authorization: .appPasscode("wrong password"), selection: selection)
                    XCTFail("Wrong vault password must refuse the read")
                } catch TOSPrivacyWalletService.Failure.authentication { }
                stage = "read verified balance through service"
                let result = try await service.read(wallet: wallet, authorization: .appPasscode(password), selection: selection)
                XCTAssertEqual(result.walletID, id)
                XCTAssertEqual(result.profile, profile)
                XCTAssertEqual(result.poolAddress, selection.address.toRaw())
                XCTAssertEqual(result.summary.unspentBalance, "0")
                XCTAssertEqual(result.summary.totalOutputs, 0)
                XCTAssertGreaterThan(result.provenShardTime, 0)
                stage = "issue consecutive private receipts"
                for expected in UInt64(0)...1 {
                    let descriptor = try await service.receive(wallet: wallet,
                        authorization: .appPasscode(password), selection: selection)
                    XCTAssertEqual(descriptor.count, 2573)
                    XCTAssertEqual(Array(descriptor.prefix(4)), [0x53, 0x48, 0x44, 0x31])
                    let index = descriptor.dropFirst(37).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    XCTAssertEqual(index, expected)
                }
                stage = "remove isolated vault"
                try await vault.deleteAll()
                XCTAssertFalse(vault.hasMnemonics())
            } catch {
                let failure = error
                XCTFail("Hosted privacy read failed at \(stage): \(diagnostic(failure))")
                do { try await vault.deleteAll() }
                catch { XCTFail("Isolated vault cleanup failed: \(diagnostic(error))") }
                throw failure
            }
        }.value
    }
}
