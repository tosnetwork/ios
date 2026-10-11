import XCTest
@testable import CoreComponents
final class TOSQuantumRecoveryInputTests: XCTestCase {
    func testRawInputRejectsMalformedAndConsumesBuffers() throws {
        let valid = TOSQuantumRecoveryInput(material: Data(String(repeating: "AB", count: 32).utf8), password: Data())
        try valid.derive(profile: .rawMaster32)
        XCTAssertEqual(valid.master, Data(repeating: 0xab, count: 32))
        XCTAssertEqual(valid.material, Data(count: 64))
        valid.material = Data("invalid".utf8)
        XCTAssertThrowsError(try valid.derive(profile: .rawMaster32))
        XCTAssertTrue(valid.master.isEmpty, "failed reuse must not retain a previous master")
        valid.master = Data(repeating: 0xab, count: 32)
        valid.wipe(); XCTAssertEqual(valid.master, Data(count: 32))
        for text in [String(repeating: "ab", count: 31), String(repeating: "ab", count: 31) + "ag", String(repeating: "ab", count: 32) + " "] {
            let input = TOSQuantumRecoveryInput(material: Data(text.utf8), password: Data())
            XCTAssertThrowsError(try input.derive(profile: .rawMaster32))
            XCTAssertTrue(input.master.isEmpty); XCTAssertEqual(input.material, Data(count: text.utf8.count))
        }
    }
    func testNativeMappingAndErrorCleanup() throws {
        let phrase = Array(repeating: "ABANDON", count: 11).joined(separator: "\u{2003}") + "\u{85}AMATEUR"
        let input = TOSQuantumRecoveryInput(material: Data(phrase.utf8), password: Data())
        try input.derive(profile: .nativeMnemonic)
        XCTAssertEqual(input.master.map { String(format: "%02x", $0) }.joined(), "cc97dcca0bed763026ad0174ad4c38a057fca97863005b181e11f9f0a0c39bc6")
        XCTAssertEqual(input.material, Data(count: phrase.utf8.count))
        input.wipe(); XCTAssertEqual(input.master, Data(count: 32))
        let bad = TOSQuantumRecoveryInput(material: Data("invalid".utf8), password: Data("password".utf8))
        XCTAssertThrowsError(try bad.derive(profile: .nativeMnemonic))
        XCTAssertEqual(bad.password, Data(count: 8)); XCTAssertEqual(bad.material, Data(count: 7))
    }
}
