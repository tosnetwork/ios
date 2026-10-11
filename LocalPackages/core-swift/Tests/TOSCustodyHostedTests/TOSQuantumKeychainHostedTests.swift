import XCTest
import Security
import CoreComponents

final class TOSQuantumKeychainHostedTests: XCTestCase {
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
