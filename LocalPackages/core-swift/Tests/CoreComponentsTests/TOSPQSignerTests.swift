import XCTest
import Security
import LocalAuthentication
@testable import CoreComponents

final class TOSPQSignerTests: XCTestCase {
    func testBothProfilesRestoreRandomizedSigningAndTamperRejection() throws {
        let seed = Data(repeating: 0xa0, count: 32) // PUBLIC TEST DATA
        for algorithm in [TOSPQAlgorithm.mldsa44, .falcon512Padded] {
            let pk = try TOSPQSigner.publicKey(algorithm: algorithm, seed: seed)
            XCTAssertEqual(pk.count, algorithm.publicKeySize)
            XCTAssertEqual(pk, try TOSPQSigner.publicKey(algorithm: algorithm, seed: seed))
            let message = algorithm == .mldsa44 ? Data(repeating: 1, count: 32) :
                Data("TOS-AUTH-FALCON512-PADDED-v1".utf8) + Data(repeating: 0, count: 5) + Data(repeating: 2, count: 32) + Data(repeating: 1, count: 32)
            let signature = try TOSPQSigner.sign(algorithm: algorithm, seed: seed, expectedPublicKey: pk, message: message)
            let second = try TOSPQSigner.sign(algorithm: algorithm, seed: seed, expectedPublicKey: pk, message: message)
            XCTAssertNotEqual(signature, second)
            XCTAssertTrue(TOSPQSigner.verify(algorithm: algorithm, publicKey: pk, message: message, signature: signature))
            var altered = message; altered[altered.count-1] ^= 1
            XCTAssertFalse(TOSPQSigner.verify(algorithm: algorithm, publicKey: pk, message: altered, signature: signature))
            var bad = signature; bad[10] ^= 1
            XCTAssertFalse(TOSPQSigner.verify(algorithm: algorithm, publicKey: pk, message: message, signature: bad))
            XCTAssertFalse(TOSPQSigner.verify(algorithm: algorithm, publicKey: pk, message: message, signature: signature.dropLast()))
            XCTAssertThrowsError(try TOSPQSigner.sign(algorithm: algorithm, seed: seed, expectedPublicKey: Data(count: pk.count), message: message))
            XCTAssertThrowsError(try TOSPQSigner.sign(algorithm: algorithm, seed: seed, expectedPublicKey: pk, message: Data()))
        }
    }
    func testIndependentPortableBackupAndAuthenticatedRestore() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tos-pq-backup-vectors", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let vectors = try XCTUnwrap(object["vectors"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 2)
        func hex(_ value: String) -> Data {
            Data(stride(from: 0, to: value.count, by: 2).map { offset in
                let start = value.index(value.startIndex, offsetBy: offset)
                return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
            })
        }
        for vector in vectors {
            let algorithm = try XCTUnwrap(TOSPQAlgorithm(rawValue: Int32(try XCTUnwrap(vector["algorithm"] as? Int))))
            let seed = hex(try XCTUnwrap(vector["seed"] as? String))
            let key = hex(try XCTUnwrap(vector["public_key"] as? String))
            let record = hex(try XCTUnwrap(vector["record"] as? String))
            let password = try XCTUnwrap(vector["password"] as? String)
            XCTAssertEqual(try TOSPQBackup.decrypt(record: record, algorithm: algorithm, network: 3, password: password), seed)
            let fresh = try TOSPQBackup.encrypt(algorithm: algorithm, network: 3, publicKey: key, seed: seed, password: password)
            XCTAssertEqual(fresh.count, 121)
            XCTAssertNotEqual(fresh, record)
            XCTAssertEqual(try TOSPQBackup.decrypt(record: fresh, algorithm: algorithm, network: 3, password: password), seed)
            XCTAssertThrowsError(try TOSPQBackup.decrypt(record: record, algorithm: algorithm, network: 4, password: password))
            let other: TOSPQAlgorithm = algorithm == .mldsa44 ? .falcon512Padded : .mldsa44
            XCTAssertThrowsError(try TOSPQBackup.decrypt(record: record, algorithm: other, network: 3, password: password))
            XCTAssertThrowsError(try TOSPQBackup.decrypt(record: record, algorithm: algorithm, network: 3, password: password + "bad"))
            var bad = record; bad[bad.count - 1] ^= 1
            XCTAssertThrowsError(try TOSPQBackup.decrypt(record: bad, algorithm: algorithm, network: 3, password: password))
            bad = record; bad[13] ^= 1
            XCTAssertThrowsError(try TOSPQBackup.decrypt(record: bad, algorithm: algorithm, network: 3, password: password))
            XCTAssertThrowsError(try TOSPQBackup.encrypt(algorithm: algorithm, network: 3, publicKey: key, seed: seed, password: "short"))
        }
    }

    func testProtectedKeychainPropagatesUnavailableProtection() throws {
        let keychain = TOSPQSeedKeychain()
        for algorithm in [TOSPQAlgorithm.mldsa44, .falcon512Padded] {
            let id = UUID()
            defer { try? keychain.delete(id: id, algorithm: algorithm) }
            let authentication = LAContext(); authentication.interactionNotAllowed = true
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                kSecAttrService: "network.tos.wallet.pq.seed.v1", kSecAttrAccount: "\(algorithm.rawValue).\(id.uuidString)",
                kSecReturnAttributes: true, kSecUseAuthenticationContext: authentication]
            do {
                let pk = try keychain.create(id: id, algorithm: algorithm)
                XCTAssertEqual(pk.count, algorithm.publicKeySize)
                var value: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &value)
                if status == errSecSuccess {
                    let attributes = try XCTUnwrap(value as? [CFString: Any])
                    XCTAssertEqual(attributes[kSecAttrAccessible] as? String, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
                    XCTAssertNotNil(attributes[kSecAttrAccessControl])
                } else {
                    XCTAssertTrue([errSecInteractionNotAllowed, errSecAuthFailed].contains(status))
                }
                // OS authentication is intentionally not bypassed for the simulator.
                print("TOS_PQ_KEYCHAIN_POLICY=created-device-only-user-presence; simulator-does-not-prove-physical-security")
            } catch let TOSPQError.keychain(status) {
                XCTAssertNotEqual(status, errSecSuccess)
                var value: CFTypeRef?
                let observed = SecItemCopyMatching(query as CFDictionary, &value)
                if status == errSecMissingEntitlement {
                    // This headless package-test host cannot inspect any Keychain item.
                    // Only failure propagation is covered here; App-hosted policy tests
                    // and a physical device are separate acceptance gates.
                    XCTAssertEqual(observed, errSecMissingEntitlement)
                    print("TOS_PQ_KEYCHAIN_POLICY=headless-host-missing-entitlement; failure-propagated")
                } else {
                    XCTAssertEqual(observed, errSecItemNotFound)
                    print("TOS_PQ_KEYCHAIN_POLICY=unavailable-failed-closed; status=\(status)")
                }
            }
        }
    }

}
