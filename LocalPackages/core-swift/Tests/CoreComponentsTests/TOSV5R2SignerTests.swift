import XCTest
@testable import CoreComponents

final class TOSV5R2SignerTests: XCTestCase {
    func testBothRolesFiveContextsAndRandomizedSignatures() throws {
        let digest = Data(repeating: 0x33, count: 32)
        for role in [TOSV5R2Role.primary, .rescue] {
            let seed = Data(repeating: 0x11, count: role.seedSize) // PUBLIC TEST FIXTURE
            let key = try TOSV5R2Signer.publicKey(role: role, seed: seed)
            XCTAssertEqual(key.count, role.publicKeySize)
            XCTAssertEqual(key, try TOSV5R2Signer.publicKey(role: role, seed: seed))
            for purpose in [TOSV5R2Purpose.auth, .pop, .preparation] {
                if role == .primary && purpose == .preparation {
                    XCTAssertThrowsError(try TOSV5R2Signer.sign(role: role, purpose: purpose, seed: seed, expectedPublicKey: key, digest: digest))
                    continue
                }
                let sig = try TOSV5R2Signer.sign(role: role, purpose: purpose, seed: seed, expectedPublicKey: key, digest: digest)
                let second = try TOSV5R2Signer.sign(role: role, purpose: purpose, seed: seed, expectedPublicKey: key, digest: digest)
                XCTAssertEqual(sig.count, role.signatureSize)
                XCTAssertNotEqual(sig, second)
                XCTAssertTrue(TOSV5R2Signer.verify(role: role, purpose: purpose, publicKey: key, digest: digest, signature: sig))
                XCTAssertFalse(TOSV5R2Signer.verify(role: role, purpose: purpose == .auth ? .pop : .auth, publicKey: key, digest: digest, signature: sig))
                var altered = sig; altered[0] ^= 1
                XCTAssertFalse(TOSV5R2Signer.verify(role: role, purpose: purpose, publicKey: key, digest: digest, signature: altered))
                XCTAssertFalse(TOSV5R2Signer.verify(role: role, purpose: purpose, publicKey: key, digest: Data(repeating: 0x34, count: 32), signature: sig))
            }
        }
    }
    func testMalformedSeedDigestSignatureAndWrongCustodyKey() throws {
        for role in [TOSV5R2Role.primary, .rescue] {
            let seed = Data(repeating: 0x11, count: role.seedSize)
            XCTAssertThrowsError(try TOSV5R2Signer.publicKey(role: role, seed: seed.dropLast()))
            let key = try TOSV5R2Signer.publicKey(role: role, seed: seed)
            let digest = Data(repeating: 0x33, count: 32)
            XCTAssertThrowsError(try TOSV5R2Signer.sign(role: role, purpose: .auth, seed: seed, expectedPublicKey: Data(repeating: 0, count: key.count), digest: digest))
            XCTAssertThrowsError(try TOSV5R2Signer.sign(role: role, purpose: .auth, seed: seed, expectedPublicKey: key, digest: digest.dropLast()))
            XCTAssertFalse(TOSV5R2Signer.verify(role: role, purpose: .auth, publicKey: key, digest: digest, signature: Data(count: 64)))
        }
    }
}
