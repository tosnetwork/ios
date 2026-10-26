import XCTest
import Security
import CoreComponents

final class TOSQuantumKeychainHostedTests: XCTestCase {
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
