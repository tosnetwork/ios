import CoreComponents
import Foundation
import XCTest

final class TOSPrivacyNativeTests: XCTestCase {
    func testNativeDescriptorMatchesRustAndConsumesSeed() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "privacy-descriptors", withExtension: "json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let vectors = try XCTUnwrap(json["vectors"] as? [[String: String]])
        var domain = Data(repeating: 0, count: 32)
        domain[31] = 7
        for vector in vectors {
            var seed = Data(repeating: 0x42, count: 32)
            let index = try XCTUnwrap(UInt64(try XCTUnwrap(vector["index"])))
            let descriptor = try TOSPrivacyNative.descriptorAndWipeSeed(seed: &seed, domain: domain, index: index)
            XCTAssertEqual(descriptor.base64EncodedString(), vector["descriptor"])
            XCTAssertEqual(seed, Data(repeating: 0, count: 32))
        }
    }

    func testRealCiphertextAndSpentStateCrossTheNativeBridge() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "privacy-scan", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var request = try XCTUnwrap(fixture["request"] as? [String: Any])
        var seed = Data(repeating: 0x42, count: 32)
        let output = try TOSPrivacyNative.scanAndWipeSeed(seed: &seed, request: JSONSerialization.data(withJSONObject: request))
        let scan = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        XCTAssertEqual(scan["batch_unspent_balance"] as? String, "1234567890")
        XCTAssertEqual(scan["next_note_key_index"] as? String, "8")
        XCTAssertEqual(seed, Data(repeating: 0, count: 32))
        request["published_nullifiers"] = [try XCTUnwrap(fixture["nullifier"] as? String)]
        seed = Data(repeating: 0x42, count: 32)
        let spent = try TOSPrivacyNative.scanAndWipeSeed(seed: &seed, request: JSONSerialization.data(withJSONObject: request))
        let settled = try XCTUnwrap(JSONSerialization.jsonObject(with: spent) as? [String: Any])
        XCTAssertEqual(settled["batch_unspent_balance"] as? String, "0")
        XCTAssertEqual(seed, Data(repeating: 0, count: 32))
    }

    func testNativeFailureStillConsumesSeed() {
        var seed = Data(repeating: 0x42, count: 32)
        XCTAssertThrowsError(try TOSPrivacyNative.scanAndWipeSeed(seed: &seed, request: Data("{}".utf8)))
        XCTAssertEqual(seed, Data(repeating: 0, count: 32))
        seed = Data(repeating: 0x42, count: 31)
        XCTAssertThrowsError(try TOSPrivacyNative.descriptorAndWipeSeed(seed: &seed, domain: Data(), index: 0))
        XCTAssertEqual(seed, Data(repeating: 0, count: 31))
    }
}
