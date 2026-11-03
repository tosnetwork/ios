@testable import KeeperCore
import Foundation
import XCTest

final class TOSPrivacyDescriptorTests: XCTestCase {
    private func fixture() -> Data {
        var bytes = Data(repeating: 0, count: TOSPrivacyDescriptor.byteCount)
        bytes.replaceSubrange(0..<5, with: [0x53, 0x48, 0x44, 0x31, 1])
        bytes.replaceSubrange(37..<45, with: Array(repeating: UInt8(255), count: 8))
        return bytes
    }

    func testWireRoundTripAndUnsignedIndex() throws {
        let bytes = fixture(), domain = Data(repeating: 0, count: 32)
        let descriptor = try TOSPrivacyDescriptor(bytes: bytes, expectedDomain: domain)
        XCTAssertEqual(descriptor.noteKeyIndex, UInt64.max)
        XCTAssertEqual(try TOSPrivacyDescriptor(base64: descriptor.base64, expectedDomain: domain).bytes, bytes)
    }

    func testDescriptorsIssuedByPinnedRustWallet() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "privacy-descriptors", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let vectors = try XCTUnwrap(object["vectors"] as? [[String: String]])
        XCTAssertEqual(vectors.count, 2)
        var domain = Data(repeating: 0, count: 32)
        domain[31] = 7
        for vector in vectors {
            let descriptor = try TOSPrivacyDescriptor(base64: XCTUnwrap(vector["descriptor"]), expectedDomain: domain)
            XCTAssertEqual(String(descriptor.noteKeyIndex), vector["index"])
            XCTAssertEqual(descriptor.base64, vector["descriptor"])
        }
    }

    func testWrongPoolAndMalformedWireAreRejected() {
        let domain = Data(repeating: 0, count: 32)
        XCTAssertThrowsError(try TOSPrivacyDescriptor(bytes: fixture(), expectedDomain: Data(repeating: 1, count: 32)))
        for offset in [0, 4, 5, 45] {
            var bytes = fixture()
            bytes[offset] = 255
            XCTAssertThrowsError(try TOSPrivacyDescriptor(bytes: bytes, expectedDomain: domain))
        }
        XCTAssertThrowsError(try TOSPrivacyDescriptor(bytes: fixture().dropLast(), expectedDomain: domain))
        XCTAssertThrowsError(try TOSPrivacyDescriptor(base64: "not-a-descriptor", expectedDomain: domain))
    }
}
