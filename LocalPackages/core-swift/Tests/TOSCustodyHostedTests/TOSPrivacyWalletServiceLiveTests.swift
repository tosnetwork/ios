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
                XCTAssertEqual(result.summary.unspentBalance, config["expected_balance"] as? String ?? "0")
                let expectedOutputs = try XCTUnwrap(UInt64(config["expected_pool_outputs"] as? String ?? "0"))
                XCTAssertEqual(result.summary.totalOutputs, expectedOutputs)
                XCTAssertGreaterThan(result.provenShardTime, 0)
                stage = "issue consecutive private receipts"
                let checkReceiptIndices = config["payment_recipient"] == nil && config["verify_balance_only"] as? Bool != true
                for expected in (checkReceiptIndices ? [UInt64(0), 1] : []) {
                    let descriptor = try await service.receive(wallet: wallet,
                        authorization: .appPasscode(password), selection: selection)
                    XCTAssertEqual(descriptor.count, 2573)
                    XCTAssertEqual(Array(descriptor.prefix(4)), [0x53, 0x48, 0x44, 0x31])
                    let index = descriptor.dropFirst(37).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    XCTAssertEqual(index, expected)
                    if expected == 0, config["export_test_receipt"] as? Bool == true {
                        stage = "export isolated public receiving descriptor"
                        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tos-privacy-test-receipt.bin")
                        try descriptor.write(to: file, options: .atomic)
                    }
                    let valid = try await service.validateRecipient(wallet: wallet,
                        authorization: .appPasscode(password), selection: selection, input: descriptor.base64EncodedString())
                    XCTAssertTrue(valid)
                    var wrongPool = descriptor
                    wrongPool[36] ^= 1
                    let invalid = try await service.validateRecipient(wallet: wallet,
                        authorization: .appPasscode(password), selection: selection, input: wrongPool.base64EncodedString())
                    XCTAssertFalse(invalid)
                }
                if let provingDirectory = ProcessInfo.processInfo.environment["TOS_PRIVACY_LIVE_PROVER_DIRECTORY"] {
                    stage = "audit installed payment proving material"
                    let root = provingDirectory.hasPrefix("/")
                        ? URL(fileURLWithPath: provingDirectory, isDirectory: true)
                        : URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                            .appendingPathComponent(provingDirectory, isDirectory: true)
                    let prover = try await service.loadPaymentProver(wallet: wallet,
                        authorization: .appPasscode(password), selection: selection,
                        phase1: root.appendingPathComponent("phase1", isDirectory: true),
                        ceremony: root.appendingPathComponent("ceremony", isDirectory: true))
                    if let encodedRecipient = config["payment_recipient"] as? String {
                        stage = "validate isolated payment recipient"
                        let recipient = try XCTUnwrap(Data(base64Encoded: encodedRecipient))
                        let authorization = TOSPrivacyWalletService.Authorization.appPasscode(password)
                        let valid = try await service.validateRecipient(wallet: wallet, authorization: authorization,
                            selection: selection, input: encodedRecipient)
                        let loseResponse = config["verify_lost_response"] as? Bool == true
                        let startingBalance = loseResponse ? "899999999" : "1000000000"
                        guard valid, result.summary.unspentBalance == startingBalance else {
                            throw TOSPQError.invalidInput
                        }
                        let approvedRelay = try JSONSerialization.data(withJSONObject: XCTUnwrap(config["approved_relay"]))
                        stage = "request isolated Tor relay quote"
                        let offer = try await service.requestRelayOffer(wallet: wallet, authorization: authorization,
                            selection: selection, approvedRelay: approvedRelay)
                        let details = try offer.details()
                        guard details.fee == "1" else { throw TOSPQError.invalidInput }
                        stage = "prove and stage isolated payment"
                        let payment = try await service.stagePayment(wallet: wallet, authorization: authorization,
                            selection: selection, recipient: recipient, amount: "100000000", fee: details.fee,
                            quoteIdentity: details.identity, prover: prover, offer: offer)
                        stage = "submit isolated payment through Tor"
                        if loseResponse {
                            do {
                                _ = try await service.submitOrRetry(payment)
                                XCTFail("Expected the isolated Tor proxy to discard the response")
                            } catch { }
                        } else {
                            _ = try await service.submitOrRetry(payment)
                        }
                        stage = "verify sender debit against authenticated history"
                        var confirmed = false
                        for _ in 0..<30 {
                            let current = try await service.read(wallet: wallet, authorization: authorization,
                                selection: selection)
                            if current.summary.unspentBalance == (loseResponse ? "799999998" : "899999999") {
                                confirmed = true
                                break
                            }
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                        XCTAssertTrue(confirmed, "Expected the confirmed amount and fee to debit the sender")
                    }
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
