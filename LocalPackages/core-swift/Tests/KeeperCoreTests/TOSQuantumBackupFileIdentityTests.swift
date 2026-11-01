import XCTest
import TonSwift
@testable import CoreComponents
import CryptoKit
@testable import KeeperCore

final class TOSQuantumBackupFileIdentityTests: XCTestCase {
    func testProtectedReexportRetainsProvenanceAndBirthWithoutOriginalFile() throws {
        let words = Array(repeating: "abandon", count: 23) + ["chicken"] // Public native fixture.
        let indices = try words.map { UInt16(try XCTUnwrap(TonSwift.Mnemonic.words.firstIndex(of: $0))) }
        for source: UInt8 in [2, 3] {
            var phrasePassword = Data(" public test password ".utf8)
            var master = source == 2 ? try TOSQuantumMnemonic.masterAndWipePassword(words: words, password: &phrasePassword) : Data(0..<32)
            defer { master.resetBytes(in: 0..<master.count) }
            var deriveMaster = master
            var seed = try TOSQuantumKdf.deriveAndWipe(material: .primary, master: &deriveMaster,
                network: namespace, globalID: -239, account: 1, generation: 19)
            defer { seed.resetBytes(in: 0..<seed.count) }
            let primary = try TOSQuantumSigner.publicKey(role: .primary, seed: seed)
            let rescue = try TOSQuantumSigner.publicKey(role: .rescue, seed: Data(repeating: 8, count: 48))
            let snapshot = try TOSQuantumSelfPayAuthority(globalID: -239, namespace: namespace, primaryKey: primary, rescueKey: rescue)
            let birth = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: snapshot))
            let role = TOSQuantumBackupPayload.Role(role: 1, account: 1, generation: 19, seed: seed,
                publicKeyHash: Data(SHA256.hash(data: primary)), sourceProfile: source,
                wordIndices: source == 2 ? indices : [], phrasePassword: source == 2 ? Data(" public test password ".utf8) : Data(),
                master: source == 3 ? master : Data())
            var plaintext = try TOSQuantumBackupPayload.encodeUnverified(globalID: -239, root: root, file: file,
                namespace: namespace, birth: birth.toBOC(), authority: snapshot.cell.toBoc(), roles: [role])
            var original = try TOSQuantumBackupCipher.encrypt(plaintext, password: "old public backup password")
            let digest = Data(SHA256.hash(data: original)), id = UUID()
            var frame = try TOSQuantumRecoveryMaterialKeychain.encode(plaintext, id: id, birthHash: birth.cell.hash(), encryptedDigest: digest)
            plaintext.resetBytes(in: 0..<plaintext.count); original.resetBytes(in: 0..<original.count)
            var material = try TOSQuantumRecoveryMaterialKeychain.payload(frame, id: id, birthHash: birth.cell.hash(), encryptedDigest: digest)
            let session = try TOSQuantumBackupInspectionSession(protectedPayload: material, originalDigest: digest)
            material.resetBytes(in: 0..<material.count)
            defer { session.close(); frame.resetBytes(in: 0..<frame.count) }
            let retained = try TOSQuantumBackupInspection(session: session, profile: profile(), expectedNamespace: namespace)
            let refreshed = try TOSQuantumSelfPayAuthority(globalID: -239, namespace: namespace, primaryKey: primary,
                rescueKey: TOSQuantumSigner.publicKey(role: .rescue, seed: Data(repeating: 9, count: 48)))
            let current = try TOSQuantumBackupIdentityFields(globalID: -239, rootHash: root, fileHash: file,
                namespace: namespace, birthBOC: retained.fields.birthBOC, authorityBOC: refreshed.cell.toBoc())
            let exported = try session.encryptedExport(current: current, primary: primary, rescue: refreshed.rescueKey,
                selected: [.primary], password: "new public backup password")
            for selection: [TOSQuantumRole] in [[], [.primary, .primary], [.rescue]] {
                XCTAssertThrowsError(try session.encryptedExport(current: current, primary: primary, rescue: refreshed.rescueKey,
                    selected: selection, password: "new public backup password"))
            }
            XCTAssertThrowsError(try session.encryptedExport(current: current, primary: Data(count: 1312), rescue: refreshed.rescueKey,
                selected: [.primary], password: "new public backup password"))
            session.close(); frame.resetBytes(in: 0..<frame.count)
            let cold = try TOSQuantumBackupInspection(encrypted: exported, password: "new public backup password",
                profile: profile(), expectedNamespace: namespace)
            XCTAssertEqual(cold.identity.birth.address, birth.address)
            XCTAssertEqual(cold.identity.snapshot.hash, refreshed.hash)
            XCTAssertNotEqual(cold.identity.birth.address, try TOSQuantumSelfPayWallet(authority: refreshed).address)
            var restored = try TOSQuantumBackupCipher.decrypt(exported, password: "new public backup password")
            defer { restored.resetBytes(in: 0..<restored.count) }
            let parsed = try TOSQuantumBackupPayload.parseUnverified(restored)
            defer { parsed.wipe() }
            XCTAssertEqual(parsed.roles[0].seed, seed)
            XCTAssertEqual(parsed.roles[0].account, 1); XCTAssertEqual(parsed.roles[0].generation, 19)
            if source == 2 {
                XCTAssertEqual(parsed.roles[0].wordIndices, indices)
                XCTAssertEqual(parsed.roles[0].phrasePassword, Data(" public test password ".utf8))
            } else { XCTAssertEqual(parsed.roles[0].master, master) }
            try parsed.validateProvenance()
        }
    }

    func testMixedCurrentAndStaleRolesRemainIndependent() throws {
        let snapshot = try authority()
        let primaryChanged = try authority(key: 9)
        XCTAssertEqual(TOSQuantumBackupInspection.compare(role: .primary, snapshot: snapshot, current: primaryChanged), .stale)
        XCTAssertEqual(TOSQuantumBackupInspection.compare(role: .rescue, snapshot: snapshot, current: primaryChanged), .matchesCurrent)
        let rescueChanged = try TOSQuantumSelfPayAuthority(globalID: -239, namespace: namespace,
            primaryKey: snapshot.primaryKey, rescueKey: Data(repeating: 9, count: 32))
        XCTAssertEqual(TOSQuantumBackupInspection.compare(role: .primary, snapshot: snapshot, current: rescueChanged), .matchesCurrent)
        XCTAssertEqual(TOSQuantumBackupInspection.compare(role: .rescue, snapshot: snapshot, current: rescueChanged), .stale)
        for role in [TOSQuantumRole.primary, .rescue] {
            XCTAssertEqual(TOSQuantumBackupInspection.compare(role: role, snapshot: snapshot, current: nil), .unavailable)
        }
    }

    func testEncryptedInspectionBindsSecretsAndExposesOnlyPublicResult() throws {
        let password = "public inspection password"
        let primarySeed = Data(repeating: 7, count: 32)
        let rescueSeed = Data(repeating: 8, count: 48)
        let primary = try TOSQuantumSigner.publicKey(role: .primary, seed: primarySeed)
        let rescue = try TOSQuantumSigner.publicKey(role: .rescue, seed: rescueSeed)
        let snapshot = try TOSQuantumSelfPayAuthority(globalID: -239, namespace: namespace,
            primaryKey: primary, rescueKey: rescue)
        let birth = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: snapshot))
        let role = TOSQuantumBackupPayload.Role(role: 2, account: 4, generation: 5,
            seed: rescueSeed, publicKeyHash: Data(SHA256.hash(data: rescue)), sourceProfile: 1,
            wordIndices: [], phrasePassword: Data(), master: Data())
        // Preserve the actual wire input, rather than asking the BOC encoder for another representation.
        let originalBirthBOC = try birth.toBOC()
        func encrypt(_ role: TOSQuantumBackupPayload.Role) throws -> Data {
            var plaintext = try TOSQuantumBackupPayload.encodeUnverified(globalID: -239, root: root,
                file: file, namespace: namespace, birth: originalBirthBOC, authority: snapshot.cell.toBoc(), roles: [role])
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            return try TOSQuantumBackupCipher.encrypt(plaintext, password: password)
        }
        let encrypted = try encrypt(role)
        let result = try TOSQuantumBackupInspection(encrypted: encrypted, password: password,
            profile: profile(), expectedNamespace: namespace)
        XCTAssertEqual(result.identity.birth.address, birth.address)
        XCTAssertEqual(result.roles.count, 1)
        XCTAssertEqual(result.roles[0].role, .rescue)
        XCTAssertEqual(result.roles[0].account, 4)
        XCTAssertEqual(result.roles[0].generation, 5)
        XCTAssertEqual(result.fields.birthBOC, originalBirthBOC)
        XCTAssertThrowsError(try TOSQuantumBackupInspection(encrypted: encrypted, password: "wrong public password",
            profile: profile(), expectedNamespace: namespace))
        XCTAssertThrowsError(try TOSQuantumBackupInspection(encrypted: encrypted, password: password,
            profile: profile(root: 6), expectedNamespace: namespace))
        var incorrect = role
        incorrect.seed[0] ^= 1
        XCTAssertThrowsError(try TOSQuantumBackupInspection(encrypted: encrypt(incorrect), password: password,
            profile: profile(), expectedNamespace: namespace))
        let session = try TOSQuantumBackupInspectionSession(encrypted: encrypted, password: password)
        session.close()
        XCTAssertThrowsError(try session.validateSecrets(primary: primary, rescue: rescue))
    }

    private let namespace = Data(repeating: 3, count: 32)
    private let root = Data(repeating: 4, count: 32)
    private let file = Data(repeating: 5, count: 32)
    private func authority(global: Int32 = -239, namespace: Data? = nil, key: UInt8 = 7) throws -> TOSQuantumSelfPayAuthority {
        try TOSQuantumSelfPayAuthority(globalID: global, namespace: namespace ?? self.namespace,
            primaryKey: Data(repeating: key, count: 1312), rescueKey: Data(repeating: 8, count: 32))
    }
    private func profile(global: Int32 = -239, root: UInt8 = 4, file: UInt8 = 5) throws -> TOSQuantumNetworkProfile {
        try TOSQuantumNetworkProfile(globalID: global,
            rootHash: String(repeating: String(format: "%02x", root), count: 32),
            fileHash: String(repeating: String(format: "%02x", file), count: 32))
    }
    private func fields(birth: Data, snapshot: Data) throws -> TOSQuantumBackupIdentityFields {
        try TOSQuantumBackupIdentityFields(globalID: -239, rootHash: root, fileHash: file,
            namespace: namespace, birthBOC: birth, authorityBOC: snapshot)
    }

    func testOriginalBirthPreservedAcrossSnapshotKeyChangeAndProfileBound() throws {
        let birth = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: authority()))
        let snapshot = try authority(key: 9)
        let metadata = try fields(birth: birth.toBOC(), snapshot: snapshot.cell.toBoc())
        let validated = try TOSQuantumBackupFileIdentity(fields: metadata, profile: profile(), expectedNamespace: namespace)
        XCTAssertEqual(validated.birth.address, birth.address)
        XCTAssertEqual(validated.snapshot.hash, snapshot.hash)
        XCTAssertNotEqual(validated.birth.address, try TOSQuantumSelfPayWallet(authority: snapshot).address)
        XCTAssertThrowsError(try TOSQuantumBackupFileIdentity(fields: metadata, profile: profile(global: -238), expectedNamespace: namespace))
        XCTAssertThrowsError(try TOSQuantumBackupFileIdentity(fields: metadata, profile: profile(root: 6), expectedNamespace: namespace))
        XCTAssertThrowsError(try TOSQuantumBackupFileIdentity(fields: metadata, profile: profile(file: 6), expectedNamespace: namespace))
        XCTAssertThrowsError(try TOSQuantumBackupFileIdentity(fields: metadata, profile: profile(), expectedNamespace: Data(count: 32)))
    }

    func testMalformedAndForeignBirthAndAuthorityRejected() throws {
        let good = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: authority())).toBOC()
        let foreign = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: authority(global: -238))).toBOC()
        let snapshot = try authority().cell.toBoc()
        let foreignSnapshot = try authority(namespace: Data(count: 32)).cell.toBoc()
        for (birth, authority) in [(foreign, snapshot), (good, foreignSnapshot), (Data([1]), snapshot),
                                   (good, Data([1])), (good + Data([0]), snapshot), (good, snapshot + Data([0]))] {
            XCTAssertThrowsError(try TOSQuantumBackupFileIdentity(fields: fields(birth: birth, snapshot: authority),
                profile: profile(), expectedNamespace: namespace))
        }
    }
}
