import XCTest
@testable import CoreComponents

final class TOSQuantumRegisteredContextTests: XCTestCase {
    func testProtectedRoleHeaderRetainsActualAccountAndGeneration() throws {
        let id = UUID(), network = Data(repeating: 3, count: 32)
        for role in [TOSQuantumRole.primary, .rescue] {
            let original = try TOSQuantumSeedKeychain.Context(network: network, globalID: -239,
                account: UInt32.max, generation: 17)
            let record = TOSQuantumSeedKeychain.header(id: id, role: role, context: original) + Data(count: role.seedSize)
            let context = try TOSQuantumSeedKeychain.registeredContext(record: record, id: id, role: role,
                network: network, globalID: -239)
            XCTAssertEqual(context.account, UInt32.max)
            XCTAssertEqual(context.generation, 17)
            XCTAssertEqual(context.network, network)
            XCTAssertThrowsError(try TOSQuantumSeedKeychain.registeredContext(record: record, id: UUID(), role: role,
                network: network, globalID: -239))
            XCTAssertThrowsError(try TOSQuantumSeedKeychain.registeredContext(record: record, id: id, role: role,
                network: Data(count: 32), globalID: -239))
            XCTAssertThrowsError(try TOSQuantumSeedKeychain.registeredContext(record: record, id: id, role: role,
                network: network, globalID: -238))
            for offset in [0, 8, 9] {
                var wrong = record; wrong[offset] ^= 1
                XCTAssertThrowsError(try TOSQuantumSeedKeychain.registeredContext(record: wrong, id: id, role: role,
                    network: network, globalID: -239))
            }
            for input in [Data(record.dropLast()), record + Data([0])] {
                XCTAssertThrowsError(try TOSQuantumSeedKeychain.registeredContext(record: input, id: id, role: role,
                    network: network, globalID: -239))
            }
        }
    }
}
