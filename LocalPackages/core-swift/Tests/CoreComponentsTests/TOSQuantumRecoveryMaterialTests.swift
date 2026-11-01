import XCTest
@testable import CoreComponents

final class TOSQuantumRecoveryMaterialTests: XCTestCase {
    func testFrameBindsTransactionBirthAndOriginalFile() throws {
        let id = UUID(), birth = Data(repeating: 3, count: 32), digest = Data(repeating: 4, count: 32)
        let payload = Data([1, 2, 3]) // Public frame-only fixture, not a validated wallet payload.
        let record = try TOSQuantumRecoveryMaterialKeychain.encode(payload, id: id, birthHash: birth, encryptedDigest: digest)
        XCTAssertEqual(try TOSQuantumRecoveryMaterialKeychain.payload(record, id: id, birthHash: birth, encryptedDigest: digest), payload)
        XCTAssertThrowsError(try TOSQuantumRecoveryMaterialKeychain.payload(record, id: UUID(), birthHash: birth, encryptedDigest: digest))
        XCTAssertThrowsError(try TOSQuantumRecoveryMaterialKeychain.payload(record, id: id, birthHash: Data(count: 32), encryptedDigest: digest))
        XCTAssertThrowsError(try TOSQuantumRecoveryMaterialKeychain.payload(record, id: id, birthHash: birth, encryptedDigest: Data(count: 32)))
        for offset in [0, 88, 91] {
            var wrong = record; wrong[offset] ^= 255
            XCTAssertThrowsError(try TOSQuantumRecoveryMaterialKeychain.payload(wrong, id: id, birthHash: birth, encryptedDigest: digest))
        }
        for size in 0..<record.count {
            XCTAssertThrowsError(try TOSQuantumRecoveryMaterialKeychain.payload(Data(record.prefix(size)), id: id, birthHash: birth, encryptedDigest: digest))
        }
        XCTAssertThrowsError(try TOSQuantumRecoveryMaterialKeychain.payload(record + Data([0]), id: id, birthHash: birth, encryptedDigest: digest))
        XCTAssertThrowsError(try TOSQuantumRecoveryMaterialKeychain.encode(Data(), id: id, birthHash: birth, encryptedDigest: digest))
        XCTAssertThrowsError(try TOSQuantumRecoveryMaterialKeychain.encode(Data(count: 262145), id: id, birthHash: birth, encryptedDigest: digest))
    }
}
