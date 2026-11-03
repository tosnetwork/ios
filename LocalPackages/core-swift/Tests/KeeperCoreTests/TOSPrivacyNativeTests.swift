import CoreComponents
import Foundation
import XCTest

final class TOSPrivacyNativeTests: XCTestCase {
    func testHistoryTransactionChecksEveryBinding() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "privacy-history", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let request = try XCTUnwrap(fixture["request"] as? [String: Any])
        func hash(_ name: String) throws -> Data {
            let text = try XCTUnwrap(request[name] as? String)
            return Data(try stride(from: 0, to: text.count, by: 2).map { offset in
                let a = text.index(text.startIndex, offsetBy: offset)
                return try XCTUnwrap(UInt8(text[a..<text.index(a, offsetBy: 2)], radix: 16))
            })
        }
        let boc = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(request["boc"] as? String)))
        let lt = try XCTUnwrap(UInt64(try XCTUnwrap(request["expected_lt"] as? String)))
        let time = try XCTUnwrap(UInt32(try XCTUnwrap(request["maximum_time"] as? String)))
        let expected = try hash("expected_hash"), account = try hash("account_id"), state = try hash("post_state_hash")
        let result = try TOSPrivacyNative.decodeHistoryTransaction(boc: boc, expectedHash: expected, logicalTime: lt,
            accountID: account, postStateHash: state, maximumTime: time)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(decoded["logical_time"] as? String, String(lt))
        XCTAssertEqual((decoded["event"] as? [String: Any])?["kind"] as? String, "transact")
        for i in 0..<5 {
            XCTAssertThrowsError(try TOSPrivacyNative.decodeHistoryTransaction(boc: boc,
                expectedHash: i == 0 ? Data(repeating: 1, count: 32) : expected, logicalTime: i == 1 ? UInt64.max : lt,
                accountID: i == 2 ? Data(repeating: 1, count: 32) : account,
                postStateHash: i == 3 ? Data(repeating: 1, count: 32) : state, maximumTime: i == 4 ? 0 : time))
        }
    }

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

    func testPoolStateDataHashBindingAndFullWireSize() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "privacy-pool-state", withExtension: "boc"))
        let boc = try Data(contentsOf: url)
        let expectedHex = "50ba96d38f3e0e474737a1946973f7ba528775a246bbe9b8d02a97a0425d6b4f"
        let chars = Array(expectedHex.utf8)
        func nibble(_ b: UInt8) -> UInt8 { b <= 57 ? b - 48 : b - 87 }
        let expected = Data(stride(from: 0, to: chars.count, by: 2).map { (nibble(chars[$0]) << 4) | nibble(chars[$0 + 1]) })
        let decoded = try TOSPrivacyNative.decodePoolState(boc: boc, expectedDataHash: expected)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        XCTAssertEqual(object["withdrawal_fee"] as? String, "20000000")
        XCTAssertEqual(object["last_anchor_epoch"] as? String, "4294967295")
        XCTAssertThrowsError(try TOSPrivacyNative.decodePoolState(boc: boc, expectedDataHash: Data(repeating: 0, count: 32))) { error in
            guard case TOSPrivacyNative.Failure.stateBinding = error else { return XCTFail("Expected data root binding failure") }
        }
        let width = Int(boc[4] & 7), start = 6 + 3 * Int(boc[4] & 7)
        XCTAssertEqual(width, 1)
        let end = start + Int(boc[5])
        let total = boc[start..<end].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        var changed = Data(boc.prefix(start))
        changed[5] = 8
        var oversized = (total + (1 << 32)).bigEndian
        withUnsafeBytes(of: &oversized) { changed.append(contentsOf: $0) }
        changed.append(boc.suffix(from: end))
        XCTAssertThrowsError(try TOSPrivacyNative.decodePoolState(boc: changed, expectedDataHash: expected))
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
