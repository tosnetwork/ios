import XCTest
import CryptoKit
import TonSwift
@testable import CoreComponents
@testable import KeeperCore

/// All secrets/passwords here are public frozen test vectors. Never use them for funds.
final class TOSQuantumBackupExchangeTests: XCTestCase {
    func testProduceMixedRoleExchangeFile() throws {
        let namespace = Data(repeating: 3, count: 32), root = Data(repeating: 4, count: 32), file = Data(repeating: 5, count: 32)
        let words = Array(repeating: "abandon", count: 23) + ["chicken"]
        let indices = try words.map { UInt16(try XCTUnwrap(TonSwift.Mnemonic.words.firstIndex(of: $0))) }
        var phrase = Data(" public test password ".utf8)
        var primaryMaster = try TOSQuantumMnemonic.masterAndWipePassword(words: words, password: &phrase)
        var rescueMaster = Data(0..<32), rescueInput = rescueMaster
        defer { rescueMaster.resetBytes(in: 0..<rescueMaster.count) }
        var primarySeed = try TOSQuantumKdf.deriveAndWipe(material: .primary, master: &primaryMaster,
            network: namespace, globalID: -239, account: 1, generation: 19)
        var rescueSeed = try TOSQuantumKdf.deriveAndWipe(material: .rescue, master: &rescueInput,
            network: namespace, globalID: -239, account: 2, generation: 20)
        defer { primarySeed.resetBytes(in: 0..<primarySeed.count); rescueSeed.resetBytes(in: 0..<rescueSeed.count) }
        let primary = try TOSQuantumSigner.publicKey(role: .primary, seed: primarySeed)
        let rescue = try TOSQuantumSigner.publicKey(role: .rescue, seed: rescueSeed)
        let authority = try TOSQuantumSelfPayAuthority(globalID: -239, namespace: namespace, primaryKey: primary, rescueKey: rescue)
        let birth = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: authority))
        var roles = [TOSQuantumBackupPayload.Role(role: 1, account: 1, generation: 19, seed: primarySeed,
            publicKeyHash: Data(SHA256.hash(data: primary)), sourceProfile: 2, wordIndices: indices,
            phrasePassword: Data(" public test password ".utf8), master: Data()),
            TOSQuantumBackupPayload.Role(role: 2, account: 2, generation: 20, seed: rescueSeed,
            publicKeyHash: Data(SHA256.hash(data: rescue)), sourceProfile: 3, wordIndices: [],
            phrasePassword: Data(), master: rescueMaster)]
        defer { for index in roles.indices { roles[index].wipe() } }
        var plaintext = try TOSQuantumBackupPayload.encodeUnverified(globalID: -239, root: root, file: file,
            namespace: namespace, birth: birth.toBOC(), authority: authority.cell.toBoc(), roles: roles)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let initial = try TOSQuantumBackupCipher.encrypt(plaintext, password: "old public exchange password")
        let session = try TOSQuantumBackupInspectionSession(encrypted: initial, password: "old public exchange password")
        defer { session.close() }
        _ = try session.validateSecrets(primary: primary, rescue: rescue)
        let exported = try session.encryptedExport(current: session.identity, primary: primary, rescue: rescue,
            selected: [.primary, .rescue], password: "public exchange password 😀")
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        let metadata: [String: Any] = ["producer": "ios", "is_public_test_material": true,
            "password": "public exchange password 😀", "global_id": -239,
            "root_hash": hex(root), "file_hash": hex(file), "namespace": hex(namespace),
            "birth_address": "0:" + hex(birth.address.hash), "authority_hash": hex(authority.hash),
            "cipher_sha256": hex(Data(SHA256.hash(data: exported))),
            "primary_key_hash": hex(Data(SHA256.hash(data: primary))), "rescue_key_hash": hex(Data(SHA256.hash(data: rescue)))]
        let binary = XCTAttachment(data: exported, uniformTypeIdentifier: "public.data")
        binary.name = "ios-public-mixed-role-v1.tosqbk"; binary.lifetime = .keepAlways; add(binary)
        let manifest = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
            uniformTypeIdentifier: "public.json")
        manifest.name = "ios-public-mixed-role-v1.json"; manifest.lifetime = .keepAlways; add(manifest)
    }
}
