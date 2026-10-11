import XCTest
@testable import CoreComponents

final class TOSQuantumSeedKeychainTests: XCTestCase {
    func testRoleRecordBindsIdentityAndContext() throws {
        let id = UUID()
        let context = try TOSQuantumSeedKeychain.Context(network: Data(repeating: 1, count: 32), globalID: 42, account: 0, generation: 0)
        let wrong = try TOSQuantumSeedKeychain.Context(network: Data(repeating: 1, count: 32), globalID: 43, account: 0, generation: 0)
        for role in [TOSQuantumRole.primary, .rescue] {
            let seed = Data(repeating: 9, count: role.seedSize)
            let header = TOSQuantumSeedKeychain.header(id: id, role: role, context: context)
            XCTAssertEqual(header.count, 69)
            let record = header + seed
            XCTAssertEqual(try TOSQuantumSeedKeychain.seed(record: record, id: id, role: role, context: context), seed)
            XCTAssertThrowsError(try TOSQuantumSeedKeychain.seed(record: record, id: UUID(), role: role, context: context))
            XCTAssertThrowsError(try TOSQuantumSeedKeychain.seed(record: record, id: id, role: role, context: wrong))
            XCTAssertThrowsError(try TOSQuantumSeedKeychain.seed(record: record.dropLast(), id: id, role: role, context: context))
        }
    }
    func testInvalidSeedIsWipedBeforeKeychainWrite() throws {
        let context = try TOSQuantumSeedKeychain.Context(network: Data(count: 32), globalID: 42, account: 0, generation: 0)
        var seed = Data(repeating: 9, count: 16)
        XCTAssertThrowsError(try TOSQuantumSeedKeychain().importAndWipe(id: UUID(), role: .primary, context: context, seed: &seed))
        XCTAssertEqual(seed, Data(count: 16))
    }
}
