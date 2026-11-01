import XCTest
@testable import CoreComponents

final class TOSQuantumBackupCipherTests: XCTestCase {
    private let password = "public vector password 😀"
    private var vector: Data {
        let hex = "544f5351424b303101000102030405060708090a0b0c0d0e0f" +
            "101112131415161718191a1b00000010" +
            "6fd50eeb2c0badf12aef5f95b250a71f54d7da98c4df951ba88e41da3d23d2e4"
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    func testIndependentNodeVector() throws {
        XCTAssertEqual(try TOSQuantumBackupCipher.decrypt(vector, password: password), Data(0..<16))
    }

    func testFreshRandomnessAndRoundtrip() throws {
        let payload = Data(0..<128)
        let first = try TOSQuantumBackupCipher.encrypt(payload, password: password)
        let second = try TOSQuantumBackupCipher.encrypt(payload, password: password)
        XCTAssertNotEqual(first[9..<25], second[9..<25])
        XCTAssertNotEqual(first[25..<37], second[25..<37])
        XCTAssertEqual(try TOSQuantumBackupCipher.decrypt(first, password: password), payload)
        XCTAssertEqual(try TOSQuantumBackupCipher.decrypt(second, password: password), payload)
    }

    func testWrongPasswordAndTamperingRejected() {
        XCTAssertThrowsError(try TOSQuantumBackupCipher.decrypt(vector, password: "different public password"))
        for offset in [0, 8, 9, 25, 37, 41, vector.count - 1] {
            var bytes = vector
            bytes[offset] ^= 1
            XCTAssertThrowsError(try TOSQuantumBackupCipher.decrypt(bytes, password: password))
        }
    }

    func testTruncationAndTrailingBytesRejected() {
        for size in 0..<vector.count {
            XCTAssertThrowsError(try TOSQuantumBackupCipher.decrypt(Data(vector.prefix(size)), password: password))
        }
        XCTAssertThrowsError(try TOSQuantumBackupCipher.decrypt(vector + Data([0]), password: password))
    }
}
