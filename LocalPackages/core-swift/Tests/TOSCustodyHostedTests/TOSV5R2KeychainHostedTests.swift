import XCTest
import Security
import CoreComponents

final class TOSV5R2KeychainHostedTests: XCTestCase {
    func testPublicKeyReadRefusesMissingRoleRecord() throws {
        let context = try TOSV5R2SeedKeychain.Context(network: Data(count: 32), globalID: 1, account: 0, generation: 0)
        let id = UUID()
        for role in [TOSV5R2Role.primary, .rescue] {
            do {
                _ = try TOSV5R2SeedKeychain().publicKey(id: id, role: role, context: context)
                XCTFail("Missing custody record returned a public key")
            } catch {
                guard let error = error as? TOSPQError, case .keychain(let status) = error else { throw error }
                XCTAssertEqual(status, errSecItemNotFound)
            }
        }
    }
}
