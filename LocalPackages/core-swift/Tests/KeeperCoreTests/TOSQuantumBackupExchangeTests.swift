import XCTest
import CryptoKit
import TonSwift
@testable import CoreComponents
@testable import KeeperCore

/// All secrets/passwords here are public frozen test vectors. Never use them for funds.
final class TOSQuantumBackupExchangeTests: XCTestCase {
    func testImportsActualAndroidMixedRoleFile() throws {
        let directory = try XCTUnwrap(Bundle.module.url(forResource: "quantum-backup-exchange-v1", withExtension: nil))
        let bytes = try Data(contentsOf: directory.appendingPathComponent("android-public-mixed-role-v1.tosqbk"))
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("android-public-mixed-role-v1.json"))) as? [String: Any])
        func hex(_ value: Data) -> String { value.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(expected["producer"] as? String, "android")
        XCTAssertEqual(expected["is_public_test_material"] as? Bool, true)
        XCTAssertEqual(expected["cipher_sha256"] as? String, hex(Data(SHA256.hash(data: bytes))))
        // Trust values are specified by test code, not selected by the incoming backup.
        let profile = try TOSQuantumNetworkProfile(globalID: -239, rootHash: String(repeating: "03", count: 32),
            fileHash: String(repeating: "04", count: 32))
        let namespace = Data(32..<64)
        let inspection = try TOSQuantumBackupInspection(encrypted: bytes, password: "public exchange password 😀",
            profile: profile, expectedNamespace: namespace)
        XCTAssertEqual(expected["birth_address"] as? String, "0:" + hex(inspection.identity.birth.address.hash))
        XCTAssertEqual(expected["authority_hash"] as? String, hex(inspection.identity.snapshot.hash))
        XCTAssertEqual(expected["primary_key_hash"] as? String, hex(Data(SHA256.hash(data: inspection.identity.snapshot.primaryKey))))
        XCTAssertEqual(expected["rescue_key_hash"] as? String, hex(Data(SHA256.hash(data: inspection.identity.snapshot.rescueKey))))
        XCTAssertEqual(inspection.roles.map(\.role), [.primary, .rescue])
        XCTAssertEqual(inspection.roles.map(\.account), [1, 2])
        XCTAssertEqual(inspection.roles.map(\.generation), [19, 20])
        XCTAssertEqual(inspection.roles.map(\.sourceProfile), [2, 3])
        var plaintext = try TOSQuantumBackupCipher.decrypt(bytes, password: "public exchange password 😀")
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let parsed = try TOSQuantumBackupPayload.parseUnverified(plaintext)
        defer { parsed.wipe() }
        let words = Array(repeating: "abandon", count: 23) + ["chicken"]
        let indices = try words.map { UInt16(try XCTUnwrap(TonSwift.Mnemonic.words.firstIndex(of: $0))) }
        XCTAssertEqual(parsed.roles.first?.wordIndices, indices)
        XCTAssertEqual(parsed.roles.first?.phrasePassword, Data(" public test password ".utf8))
        XCTAssertEqual(parsed.roles.last?.master, Data(0..<32))
        XCTAssertThrowsError(try TOSQuantumBackupInspection(encrypted: bytes, password: "incorrect public exchange password",
            profile: profile, expectedNamespace: namespace))
        let wrong = try TOSQuantumNetworkProfile(globalID: -238, rootHash: profile.rootHash, fileHash: profile.fileHash)
        XCTAssertThrowsError(try TOSQuantumBackupInspection(encrypted: bytes, password: "public exchange password 😀",
            profile: wrong, expectedNamespace: namespace))
        var tampered = bytes; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try TOSQuantumBackupInspection(encrypted: tampered, password: "public exchange password 😀",
            profile: profile, expectedNamespace: namespace))
    }

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
