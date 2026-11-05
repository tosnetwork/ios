import Foundation
import CryptoKit
import TonSwift
import TKKeychain
import XCTest
@testable import CoreComponents
@testable import KeeperCore

final class TOSPrivacyWalletReadTests: XCTestCase {
    private func summary(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> TOSPrivacySummary {
        var value: [String: Any] = ["version": 1, "total_outputs": "4", "owned_outputs": "3",
            "unique_unspent_notes": "1", "duplicate_outputs": "1", "reused_indices_count": "1",
            "diagnostics_count": "0", "unspent_balance": "18446744073709551617", "scan_next_index": "8"]
        mutate(&value)
        return try TOSPrivacySummary(nativeJSON: JSONSerialization.data(withJSONObject: value))
    }
    func testObservedSummaryKeepsExactDecimalsAndExplicitExhaustion() throws {
        XCTAssertEqual(try summary().unspentBalance, "18446744073709551617")
        XCTAssertEqual(try summary().scanNextIndex, 8)
        XCTAssertNil(try summary { $0["scan_next_index"] = NSNull() }.scanNextIndex)
        XCTAssertEqual(try summary { $0["unspent_balance"] = "340282366920938463463374607431768211455" }.unspentBalance,
                       "340282366920938463463374607431768211455")
    }
    func testPrivateBalanceFormatsFullU128AndNanoBoundariesExactly() throws {
        for (nano, expected) in [
            ("0", "0 TOS"), ("1", "0.000000001 TOS"), ("1000000000", "1 TOS"),
            ("1200000000", "1.2 TOS"), ("1000000010", "1.00000001 TOS"),
            ("18446744073709551617", "18446744073.709551617 TOS"),
            ("340282366920938463463374607431768211455", "340282366920938463463374607431.768211455 TOS")
        ] {
            XCTAssertEqual(try summary { $0["unspent_balance"] = nano }.formattedBalance, expected)
        }
    }
    func testObservedSummaryRejectsNumericLossMalformedAndInconsistentResults() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["version"] = true }, { $0["unspent_balance"] = 1 }, { $0["unspent_balance"] = "01" },
            { $0["unspent_balance"] = "1e3" }, { $0["unspent_balance"] = "-1" },
            { $0["unspent_balance"] = "340282366920938463463374607431768211456" },
            { $0["owned_outputs"] = "5" }, { $0["unique_unspent_notes"] = "0" },
            { $0["diagnostics_count"] = "5" }, { $0["total_outputs"] = 4 },
            { $0["scan_next_index"] = "18446744073709551616" }, { $0["unexpected"] = true },
            { $0.removeValue(forKey: "unspent_balance") }
        ]
        for mutation in mutations { XCTAssertThrowsError(try summary(mutation)) }
        XCTAssertThrowsError(try TOSPrivacySummary(nativeJSON: Data(count: 8193)))
    }
    func testPoolRegistryHasNoDiscoveryAndSeparatesSameGlobalDifferentGenesis() throws {
        let registry = TOSPrivacyPoolRegistry()
        let a = try TOSQuantumNetworkProfile(globalID: 3, rootHash: String(repeating: "12", count: 32), fileHash: String(repeating: "34", count: 32))
        let b = try TOSQuantumNetworkProfile(globalID: 3, rootHash: String(repeating: "56", count: 32), fileHash: String(repeating: "34", count: 32))
        XCTAssertNil(registry.selection(for: a))
        let selection = try TOSPrivacyPoolSelection(profile: a, address: Address(workchain: 0, hash: Data(repeating: 2, count: 32)),
            codeBOC: Builder().endCell().toBoc(), profileHash: Data(repeating: 1, count: 32),
            manifestHash: Data(repeating: 2, count: 32), verifyingKeyHash: Data(repeating: 3, count: 32), sourceDescription: "Explicit test expectations")
        try registry.registerApproved(selection)
        XCTAssertEqual(registry.selection(for: a)?.address, selection.address)
        XCTAssertNil(registry.selection(for: b))
    }
    func testCustodyPreparationPrefersOrdinaryProvenanceAndNeverDowngradesCorruption() async throws {
        let assets = try XCTUnwrap(Bundle.module.url(forResource: "quantum-self-pay-live", withExtension: nil))
        let bytes = try Data(contentsOf: assets.appendingPathComponent("public-self-pay-accounts.json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let accounts = try XCTUnwrap(fixture["accounts"] as? [String: [String: Any]])
        let encoded = try XCTUnwrap(accounts["active"]?["identity_boc"] as? String)
        let identity = try TOSQuantumSelfPayIdentity(boc: XCTUnwrap(Data(base64Encoded: encoded)))
        let global = identity.wallet.initialAuthority.globalID
        let profile = try TOSQuantumNetworkProfile(globalID: global, rootHash: String(repeating: "12", count: 32),
                                                    fileHash: String(repeating: "34", count: 32))
        let id = UUID(), base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let outbox = base.appendingPathComponent("outbox")
        _ = try TOSQuantumOutbox(baseDirectory: outbox)
        let name = identity.cell.hash().map { String(format: "%02x", $0) }.joined()
        let recoveryURL = outbox.appendingPathComponent(name + ".recovery-record")
        let recovery = TOSQuantumOutbox.RecoveryRecord(version: 1, id: id, identity: identity, profile: profile,
                                                       encryptedDigest: Data(repeating: 7, count: 32), mode: "recovery_only")
        try JSONEncoder().encode(recovery).write(to: recoveryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryURL.path)
        let wallet = Wallet(id: id.uuidString, identity: WalletIdentity(network: .mainnet, kind: .Quantum(identity)),
            metaData: WalletMetaData(label: "Public test fixture", tintColor: .defaultColor, icon: .icon(.wallet)),
            setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
        let vault = MnemonicsVault(keychainVault: TKKeychainVaultImplementation(keychain: TKKeychainImplementation()),
                                    seedProvider: { "privacy-custody-route-" + id.uuidString })
        let service = TOSPrivacyWalletService(mnemonics: vault, baseDirectory: base, outboxDirectory: outbox,
                                              now: { Int64(Date().timeIntervalSince1970) })
        let restored = try await service.prepare(wallet: wallet)
        XCTAssertEqual(restored.profile, profile)
        XCTAssertEqual(restored.access, .devicePresence)
        try TOSQuantumCreationRecord(id: id, profile: profile, identity: identity).save(baseDirectory: base)
        let ordinary = try await service.prepare(wallet: wallet)
        XCTAssertEqual(ordinary.access, .appPasscode)
        let originalURL = base.appendingPathComponent("quantum-creation").appendingPathComponent(id.uuidString + ".json")
        try Data("not a valid creation record".utf8).write(to: originalURL)
        do {
            _ = try await service.prepare(wallet: wallet)
            XCTFail("A corrupt ordinary record must not downgrade to recovery authorization")
        } catch is DecodingError { }
    }
    private static func binding(master: Data, birthHash: Data) throws -> TOSPrivacyMasterSession.Binding {
        var copy = master
        var role = try TOSQuantumKdf.deriveAndWipe(material: .primary, master: &copy,
            network: Data(repeating: 5, count: 32), globalID: 3, account: 0, generation: 0)
        defer { role.resetBytes(in: 0..<role.count) }
        return try TOSPrivacyMasterSession.Binding(globalID: 3, namespace: Data(repeating: 5, count: 32),
            birthHash: birthHash, birthPrimaryKey: TOSQuantumSigner.publicKey(role: .primary, seed: role))
    }
    func testOriginalMasterIsBoundAndARoleSeedCannotReplaceIt() async throws {
        try await Task.detached {
            let original = Data(repeating: 0x42, count: 32)
            let binding = try Self.binding(master: original, birthHash: Data(repeating: 6, count: 32))
            var master = original
            let session = try TOSPrivacyMasterSession.boundMasterAndWipe(&master, binding: binding)
            XCTAssertEqual(master, Data(count: 32)); session.close(); session.close()
            var copy = original
            var role = try TOSQuantumKdf.deriveAndWipe(material: .primary, master: &copy,
                network: binding.namespace, globalID: binding.globalID, account: 0, generation: 0)
            XCTAssertThrowsError(try TOSPrivacyMasterSession.boundMasterAndWipe(&role, binding: binding)) { error in
                guard case TOSPrivacyMasterSession.Failure.materialUnavailable = error else { return XCTFail("Expected original-root refusal") }
            }
            XCTAssertEqual(role, Data(count: 32))
        }.value
    }
    func testMnemonicMasterUsesTheOriginalNativeDomainAndBinding() async throws {
        try await Task.detached {
            let words = Array(repeating: "abandon", count: 11) + ["amateur"] // Public native vector.
            var password = Data()
            var master = try TOSQuantumMnemonic.masterAndWipePassword(words: words, password: &password)
            defer { master.resetBytes(in: 0..<master.count) }
            let binding = try Self.binding(master: master, birthHash: Data(repeating: 6, count: 32))
            var phrasePassword = Data()
            let session = try TOSPrivacyMasterSession.mnemonic(words: words, phrasePassword: &phrasePassword, binding: binding)
            XCTAssertTrue(phrasePassword.isEmpty); session.close()
            let other = try Self.binding(master: Data(repeating: 3, count: 32), birthHash: binding.birthHash)
            XCTAssertThrowsError(try TOSPrivacyMasterSession.mnemonic(words: words, phrasePassword: &phrasePassword, binding: other))
        }.value
    }
    func testMasterSessionIsOneShotAndClosedWhenAProofRecheckFails() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "privacy-session", withExtension: "json"))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let request = try JSONSerialization.data(withJSONObject: XCTUnwrap(value["request"]))
        let transactions = try XCTUnwrap(value["transactions"] as? [String]).map { try XCTUnwrap(Data(base64Encoded: $0)) }
        try await Task.detached {
            var cursor = transactions.count - 1
            let history = try TOSPrivacyHistoryWalk.replay(request: request, query: { _, _, _ in
                defer { cursor -= 1 }; return transactions[cursor]
            }, recheck: {})
            defer { history.close() }
            for fail in [false, true] {
                var master = Data(repeating: 0x42, count: 32)
                let binding = try Self.binding(master: master, birthHash: Data(repeating: 6, count: 32))
                let session = try TOSPrivacyMasterSession.boundMasterAndWipe(&master, binding: binding)
                if fail {
                    XCTAssertThrowsError(try session.summaryAndClose(history: history, binding: binding,
                        stopped: { false }, recheck: { throw TOSPQError.keyBinding }))
                } else {
                    let result = try TOSPrivacySummary(nativeJSON: session.summaryAndClose(history: history,
                        binding: binding, stopped: { false }, recheck: {}))
                    XCTAssertEqual(result.totalOutputs, 13)
                }
                XCTAssertThrowsError(try session.summaryAndClose(history: history, binding: binding,
                    stopped: { false }, recheck: {})) { error in
                    guard case TOSPrivacyMasterSession.Failure.materialUnavailable = error else { return XCTFail("Expected consumed custody") }
                }
                XCTAssertEqual(master, Data(count: 32))
            }
        }.value
    }
    func testProtectedRoleOnlyAndRotatedRootAreUnavailableWhileOriginalMasterWorks() async throws {
        try await Task.detached {
            // Public codec/custody fixtures; not a chain account or OS Keychain acceptance.
            let birth = try Builder().store(uint: 1, bits: 8).endCell()
            let original = Data(repeating: 0x42, count: 32)
            let binding = try Self.binding(master: original, birthHash: birth.hash())
            for source: UInt8 in [1, 3] {
                for rotated in [false, true] {
                    let root = rotated ? Data(repeating: 0x43, count: 32) : original
                    var input = root
                    var seed = try TOSQuantumKdf.deriveAndWipe(material: .primary, master: &input,
                        network: binding.namespace, globalID: 3, account: 0, generation: rotated ? 1 : 0)
                    defer { seed.resetBytes(in: 0..<seed.count) }
                    let key = try TOSQuantumSigner.publicKey(role: .primary, seed: seed)
                    let role = TOSQuantumBackupPayload.Role(role: 1, account: 0, generation: rotated ? 1 : 0,
                        seed: seed, publicKeyHash: Data(SHA256.hash(data: key)), sourceProfile: source,
                        wordIndices: [], phrasePassword: Data(), master: source == 3 ? root : Data())
                    var bytes = try TOSQuantumBackupPayload.encodeUnverified(globalID: 3,
                        root: Data(repeating: 1, count: 32), file: Data(repeating: 2, count: 32), namespace: binding.namespace,
                        birth: birth.toBoc(), authority: birth.toBoc(), roles: [role])
                    defer { bytes.resetBytes(in: 0..<bytes.count) }
                    let inspected = try TOSQuantumBackupInspectionSession(protectedPayload: bytes, originalDigest: Data(repeating: 8, count: 32))
                    defer { inspected.close() }
                    XCTAssertThrowsError(try inspected.privacyMaster(binding: binding), "Unvalidated recovery material cannot supply privacy custody")
                    _ = try inspected.validateSecrets(primary: key, rescue: Data(repeating: 9, count: TOSQuantumRole.rescue.publicKeySize))
                    if source == 3 && !rotated { let master = try inspected.privacyMaster(binding: binding); master.close() }
                    else {
                        XCTAssertThrowsError(try inspected.privacyMaster(binding: binding)) { error in
                            guard case TOSPrivacyMasterSession.Failure.materialUnavailable = error else { return XCTFail("Expected unavailable original root") }
                        }
                    }
                }
            }
        }.value
    }
}
