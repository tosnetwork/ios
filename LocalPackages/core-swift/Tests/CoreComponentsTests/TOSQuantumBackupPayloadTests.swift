import XCTest
import CryptoKit
@testable import CoreComponents

final class TOSQuantumBackupPayloadTests: XCTestCase {
    func testNativeSeedsBindToFullSnapshotKeysAndDigests() throws {
        let primarySeed = Data(repeating: 7, count: 32)
        let rescueSeed = Data(repeating: 8, count: 48)
        let primary = try TOSQuantumSigner.publicKey(role: .primary, seed: primarySeed)
        let rescue = try TOSQuantumSigner.publicKey(role: .rescue, seed: rescueSeed)
        let roles = [TOSQuantumBackupPayload.Role(role: 1, account: 0, generation: 3,
            seed: primarySeed, publicKeyHash: Data(SHA256.hash(data: primary)), sourceProfile: 1,
            wordIndices: [], phrasePassword: Data(), master: Data()),
            TOSQuantumBackupPayload.Role(role: 2, account: 1, generation: 5,
            seed: rescueSeed, publicKeyHash: Data(SHA256.hash(data: rescue)), sourceProfile: 1,
            wordIndices: [], phrasePassword: Data(), master: Data())]
        func payload(_ entries: [TOSQuantumBackupPayload.Role]) throws -> TOSQuantumBackupPayload {
            try TOSQuantumBackupPayload.parseUnverified(TOSQuantumBackupPayload.encodeUnverified(
                globalID: -3, root: Data(count: 32), file: Data(count: 32), namespace: Data(count: 32),
                birth: Data([1]), authority: Data([1]), roles: entries))
        }
        let valid = try payload(roles)
        defer { valid.wipe() }
        try valid.validateSnapshotKeys(primary: primary, rescue: rescue)
        var substituted = primary
        substituted[0] ^= 1
        XCTAssertThrowsError(try valid.validateSnapshotKeys(primary: substituted, rescue: rescue))
        var wrongRescue = rescue
        wrongRescue[0] ^= 1
        XCTAssertThrowsError(try valid.validateSnapshotKeys(primary: primary, rescue: wrongRescue))
        var changed = roles
        changed[0].seed[0] ^= 1
        let wrongSeed = try payload(changed)
        defer { wrongSeed.wipe() }
        XCTAssertThrowsError(try wrongSeed.validateSnapshotKeys(primary: primary, rescue: rescue))
        changed = roles
        changed[1] = TOSQuantumBackupPayload.Role(role: 2, account: 1, generation: 5,
            seed: rescueSeed, publicKeyHash: Data(count: 32), sourceProfile: 1,
            wordIndices: [], phrasePassword: Data(), master: Data())
        let wrongHash = try payload(changed)
        defer { wrongHash.wipe() }
        XCTAssertThrowsError(try wrongHash.validateSnapshotKeys(primary: primary, rescue: rescue))
        let rescueOnly = try payload([roles[1]])
        defer { rescueOnly.wipe() }
        try rescueOnly.validateSnapshotKeys(primary: primary, rescue: rescue)
    }

    private func fixture(roles: [UInt8] = [1, 2], source: UInt8 = 1,
                         word: UInt16 = 2047, password: Data = Data()) -> Data {
        var result = Data([1, 255, 255, 255, 253])
        result.append(Data(0..<96))
        result.append(contentsOf: [0, 0, 0, 1, 9, 0, 0, 0, 1, 8, UInt8(roles.count)])
        for role in roles {
            result.append(role)
            result.append(Data(repeating: 255, count: 8))
            result.append(Data(repeating: 7, count: role == 1 ? 32 : 48))
            result.append(Data(repeating: 6, count: 32))
            result.append(source)
            if source == 2 {
                result.append(contentsOf: [1, 12])
                for _ in 0..<12 { result.append(contentsOf: [UInt8(word >> 8), UInt8(word & 255)]) }
                result.append(contentsOf: [UInt8(password.count >> 8), UInt8(password.count & 255)])
                result.append(password)
            }
            if source == 3 { result.append(Data(repeating: 5, count: 32)) }
        }
        return result
    }

    func testProfilesCountersAndOwnedSecretWipe() throws {
        for source: UInt8 in 1...3 {
            let input = fixture(source: source, password: Data("é 😀".utf8))
            let parsed = try TOSQuantumBackupPayload.parseUnverified(input)
            XCTAssertEqual(parsed.globalID, -3)
            XCTAssertEqual(parsed.roles.count, 2)
            XCTAssertEqual(parsed.roles[0].account, UInt32.max)
            XCTAssertEqual(parsed.roles[1].generation, UInt32.max)
            XCTAssertEqual(parsed.roles[1].seed.count, 48)
            if source == 2 { XCTAssertEqual(parsed.roles[0].wordIndices.first, 2047) }
            parsed.wipe()
            for role in parsed.roles {
                XCTAssertTrue(role.seed.allSatisfy { $0 == 0 })
                XCTAssertTrue(role.wordIndices.allSatisfy { $0 == 0 })
                XCTAssertTrue(role.phrasePassword.allSatisfy { $0 == 0 })
                XCTAssertTrue(role.master.allSatisfy { $0 == 0 })
            }
            XCTAssertEqual(input, fixture(source: source, password: Data("é 😀".utf8)))
        }
    }

    func testEveryTruncationAndTrailingDataRejected() {
        for source: UInt8 in 1...3 {
            let input = fixture(source: source)
            for size in 0..<input.count {
                XCTAssertThrowsError(try TOSQuantumBackupPayload.parseUnverified(Data(input.prefix(size))))
            }
            XCTAssertThrowsError(try TOSQuantumBackupPayload.parseUnverified(input + Data([0])))
        }
    }

    func testEncodingPreservesExactWireAndRejectsInvalidSource() throws {
        for source: UInt8 in 1...3 {
            let original = fixture(source: source, password: Data("é 😀".utf8))
            let parsed = try TOSQuantumBackupPayload.parseUnverified(original)
            defer { parsed.wipe() }
            XCTAssertEqual(try TOSQuantumBackupPayload.encodeUnverified(globalID: parsed.globalID,
                root: parsed.rootHash, file: parsed.fileHash, namespace: parsed.namespace,
                birth: parsed.birthBOC, authority: parsed.authorityBOC, roles: parsed.roles), original)
        }
        let parsed = try TOSQuantumBackupPayload.parseUnverified(fixture(source: 2))
        defer { parsed.wipe() }
        var invalid = parsed.roles
        defer { for index in invalid.indices { invalid[index].wipe() } }
        invalid[0].wordIndices[0] = 2048
        XCTAssertThrowsError(try TOSQuantumBackupPayload.encodeUnverified(globalID: parsed.globalID,
            root: parsed.rootHash, file: parsed.fileHash, namespace: parsed.namespace,
            birth: parsed.birthBOC, authority: parsed.authorityBOC, roles: invalid))
        XCTAssertThrowsError(try TOSQuantumBackupPayload.encodeUnverified(globalID: parsed.globalID,
            root: Data(count: 31), file: parsed.fileHash, namespace: parsed.namespace,
            birth: parsed.birthBOC, authority: parsed.authorityBOC, roles: parsed.roles))
    }

    func testInvalidRolesSourcesAndUTF8Rejected() {
        for roles: [UInt8] in [[], [1, 1], [2, 1], [3]] {
            XCTAssertThrowsError(try TOSQuantumBackupPayload.parseUnverified(fixture(roles: roles)))
        }
        for input in [fixture(source: 4), fixture(source: 2, word: 2048),
                      fixture(source: 2, password: Data(repeating: 0, count: 1025)),
                      fixture(source: 2, password: Data([0xc0, 0xaf]))] {
            XCTAssertThrowsError(try TOSQuantumBackupPayload.parseUnverified(input))
        }
    }
}
