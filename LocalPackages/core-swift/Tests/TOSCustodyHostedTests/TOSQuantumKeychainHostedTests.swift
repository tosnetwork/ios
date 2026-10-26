import XCTest
import Security
import CoreComponents
import KeeperCore

final class TOSQuantumKeychainHostedTests: XCTestCase {
    /// Run after the actual creation UI on the same dedicated app installation.
    /// Successful simulator access is not physical-device user-presence acceptance.
    func testCreatedWalletProtectedRolesMatchBirthIdentityAndSignSelfPayDomains() throws {
        guard let value = ProcessInfo.processInfo.environment["TOS_QUANTUM_CREATED_ID"], !value.isEmpty else {
            throw XCTSkip("Requires the UUID from a completed actual Quantum creation UI run")
        }
        let id = try XCTUnwrap(UUID(uuidString: value))
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: false)
        let file = base.appendingPathComponent("quantum-creation").appendingPathComponent(id.uuidString + ".json")
        let record = try JSONDecoder().decode(TOSQuantumCreationRecord.self, from: Data(contentsOf: file))
        XCTAssertEqual(record.id, id)
        let authority = record.identity.wallet.initialAuthority
        let context = try TOSQuantumSeedKeychain.Context(network: authority.namespace, globalID: authority.globalID,
                                                        account: record.account, generation: record.generation)
        let wrong = try TOSQuantumSeedKeychain.Context(network: authority.namespace, globalID: authority.globalID ^ 1,
                                                      account: record.account, generation: record.generation)
        let digest = Data(repeating: 0x42, count: 32), changed = Data(repeating: 0x24, count: 32)
        let keychain = TOSQuantumSeedKeychain()
        for role in [TOSQuantumRole.primary, .rescue] {
            let expected = role == .primary ? authority.primaryKey : authority.rescueKey
            XCTAssertEqual(try keychain.publicKey(id: id, role: role, context: context), expected)
            XCTAssertThrowsError(try keychain.publicKey(id: id, role: role, context: wrong)) { error in
                guard case TOSPQError.keyBinding = error else { return XCTFail("Unexpected binding error: \(error)") }
            }
            for purpose in [TOSQuantumPurpose.selfPay, .selfPayPop] {
                let signature = try keychain.sign(id: id, role: role, context: context, expectedPublicKey: expected,
                                                  purpose: purpose, digest: digest)
                XCTAssertTrue(TOSQuantumSigner.verify(role: role, purpose: purpose, publicKey: expected, digest: digest, signature: signature))
                XCTAssertFalse(TOSQuantumSigner.verify(role: role, purpose: purpose, publicKey: expected, digest: changed, signature: signature))
                XCTAssertFalse(TOSQuantumSigner.verify(role: role, purpose: purpose == .selfPay ? .selfPayPop : .selfPay,
                                                       publicKey: expected, digest: digest, signature: signature))
            }
        }
        print("PUBLIC_QUANTUM_CUSTODY_VERIFIED=" + id.uuidString)
    }

    func testSingleKeychainRecordSupportsVaultSizedUpdatesAndRejectsInvalidUpdateWithoutDataLoss() throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: "public.atomic.vault.test.\(UUID().uuidString)", kSecAttrAccount: "record"]
        defer { SecItemDelete(query as CFDictionary) }
        var insertion = query
        insertion[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        insertion[kSecValueData] = Data(repeating: 0x42, count: 4096)
        XCTAssertEqual(SecItemAdd(insertion as CFDictionary, nil), errSecSuccess)
        let updated = Data(repeating: 0x24, count: 65536)
        XCTAssertEqual(SecItemUpdate(query as CFDictionary, [kSecValueData: updated] as CFDictionary), errSecSuccess)
        XCTAssertNotEqual(SecItemUpdate(query as CFDictionary,
            [kSecValueData: Data(), kSecAttrAccessible: "invalid-accessibility"] as CFDictionary), errSecSuccess)
        var read = query; read[kSecReturnData] = true
        var value: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &value), errSecSuccess)
        XCTAssertEqual(value as? Data, updated)
    }

    /// Public marker records exercise real Keychain deletion and service scoping.
    /// They do not establish user-presence access or protected signing coverage.
    func testRoleDeletionAndSignOutRemoveOnlyQuantumSeedRecords() throws {
        let id = UUID(), otherID = UUID(), unrelated = "public.cleanup.test.\(UUID().uuidString)"
        let service = "network.tos.wallet.quantum.seed.v1"
        func query(_ service: String, _ account: String) -> [CFString: Any] {
            [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
             kSecAttrAccount: account, kSecAttrSynchronizable: false]
        }
        let records = [query(service, "1.\(id.uuidString)"), query(service, "2.\(id.uuidString)"),
                       query(service, "1.\(otherID.uuidString)"), query(unrelated, "preserve")]
        defer { for record in records { SecItemDelete(record as CFDictionary) } }
        for record in records {
            var insertion = record
            insertion[kSecValueData] = Data("PUBLIC TEST RECORD".utf8)
            XCTAssertEqual(SecItemAdd(insertion as CFDictionary, nil), errSecSuccess)
        }
        func exists(_ index: Int) -> OSStatus { SecItemCopyMatching(records[index] as CFDictionary, nil) }
        let keychain = TOSQuantumSeedKeychain()
        try keychain.delete(id: id, role: .primary)
        XCTAssertEqual(exists(0), errSecItemNotFound)
        for index in [1, 2, 3] { XCTAssertEqual(exists(index), errSecSuccess) }
        try keychain.deleteAll()
        for index in [0, 1, 2] { XCTAssertEqual(exists(index), errSecItemNotFound) }
        XCTAssertEqual(exists(3), errSecSuccess)
        try keychain.deleteAll()
    }

    func testPublicKeyReadRefusesMissingRoleRecord() throws {
        let context = try TOSQuantumSeedKeychain.Context(network: Data(count: 32), globalID: 1, account: 0, generation: 0)
        let id = UUID()
        for role in [TOSQuantumRole.primary, .rescue] {
            do {
                _ = try TOSQuantumSeedKeychain().publicKey(id: id, role: role, context: context)
                XCTFail("Missing custody record returned a public key")
            } catch {
                guard let error = error as? TOSPQError, case .keychain(let status) = error else { throw error }
                XCTAssertEqual(status, errSecItemNotFound)
            }
        }
    }
}
