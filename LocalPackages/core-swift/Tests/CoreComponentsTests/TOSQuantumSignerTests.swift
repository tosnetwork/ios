import XCTest
@testable import CoreComponents

final class TOSQuantumSignerTests: XCTestCase {
    func testBothRolesFiveContextsAndRandomizedSignatures() throws {
        let digest = Data(repeating: 0x33, count: 32)
        for role in [TOSQuantumRole.primary, .rescue] {
            let seed = Data(repeating: 0x11, count: role.seedSize) // PUBLIC TEST FIXTURE
            let key = try TOSQuantumSigner.publicKey(role: role, seed: seed)
            XCTAssertEqual(key.count, role.publicKeySize)
            XCTAssertEqual(key, try TOSQuantumSigner.publicKey(role: role, seed: seed))
            for purpose in [TOSQuantumPurpose.auth, .pop, .preparation] {
                if role == .primary && purpose == .preparation {
                    XCTAssertThrowsError(try TOSQuantumSigner.sign(role: role, purpose: purpose, seed: seed, expectedPublicKey: key, digest: digest))
                    continue
                }
                let sig = try TOSQuantumSigner.sign(role: role, purpose: purpose, seed: seed, expectedPublicKey: key, digest: digest)
                let second = try TOSQuantumSigner.sign(role: role, purpose: purpose, seed: seed, expectedPublicKey: key, digest: digest)
                XCTAssertEqual(sig.count, role.signatureSize)
                XCTAssertNotEqual(sig, second)
                XCTAssertTrue(TOSQuantumSigner.verify(role: role, purpose: purpose, publicKey: key, digest: digest, signature: sig))
                XCTAssertFalse(TOSQuantumSigner.verify(role: role, purpose: purpose == .auth ? .pop : .auth, publicKey: key, digest: digest, signature: sig))
                var altered = sig; altered[0] ^= 1
                XCTAssertFalse(TOSQuantumSigner.verify(role: role, purpose: purpose, publicKey: key, digest: digest, signature: altered))
                XCTAssertFalse(TOSQuantumSigner.verify(role: role, purpose: purpose, publicKey: key, digest: Data(repeating: 0x34, count: 32), signature: sig))
            }
        }
    }
    func testMalformedSeedDigestSignatureAndWrongCustodyKey() throws {
        for role in [TOSQuantumRole.primary, .rescue] {
            let seed = Data(repeating: 0x11, count: role.seedSize)
            XCTAssertThrowsError(try TOSQuantumSigner.publicKey(role: role, seed: seed.dropLast()))
            let key = try TOSQuantumSigner.publicKey(role: role, seed: seed)
            let digest = Data(repeating: 0x33, count: 32)
            XCTAssertThrowsError(try TOSQuantumSigner.sign(role: role, purpose: .auth, seed: seed, expectedPublicKey: Data(repeating: 0, count: key.count), digest: digest))
            XCTAssertThrowsError(try TOSQuantumSigner.sign(role: role, purpose: .auth, seed: seed, expectedPublicKey: key, digest: digest.dropLast()))
            XCTAssertFalse(TOSQuantumSigner.verify(role: role, purpose: .auth, publicKey: key, digest: digest, signature: Data(count: 64)))
        }
    }
}
