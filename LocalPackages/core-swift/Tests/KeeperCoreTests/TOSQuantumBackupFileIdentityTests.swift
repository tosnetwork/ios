import XCTest
import TonSwift
@testable import CoreComponents
import CryptoKit
@testable import KeeperCore

final class TOSQuantumBackupFileIdentityTests: XCTestCase {
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
        func encrypt(_ role: TOSQuantumBackupPayload.Role) throws -> Data {
            var plaintext = try TOSQuantumBackupPayload.encodeUnverified(globalID: -239, root: root,
                file: file, namespace: namespace, birth: birth.toBOC(), authority: snapshot.cell.toBoc(), roles: [role])
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
        XCTAssertEqual(result.fields.birthBOC, try birth.toBOC())
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
