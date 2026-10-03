@testable import KeeperCore
import TonSwift
import XCTest

final class TOSNetworkIdentityTests: XCTestCase {
    func testNativeWalletVMCapabilityBoundaryAndCanonicalConfig8() throws {
        for version in [UInt32(0), 3, 4, 5, 6, 18, UInt32.max] {
            let cell = try Builder().store(uint: 0xc4, bits: 8).store(uint: version, bits: 32).store(uint: 0x1ee, bits: 64).endCell()
            let result: [String: Any] = ["config": ["bytes": try cell.toBoc().base64EncodedString()]]
            let decoded = try TOSNetworkIdentity.decodeVMVersion(result)
            XCTAssertEqual(decoded, version)
            if version < 6 {
                XCTAssertThrowsError(try TOSNetworkIdentity.requireWalletVMVersion(decoded))
            } else {
                XCTAssertNoThrow(try TOSNetworkIdentity.requireWalletVMVersion(decoded))
            }
        }
        let wrongTag = try Builder().store(uint: 0xc3, bits: 8).store(uint: 18, bits: 32).store(uint: 0, bits: 64).endCell()
        let short = try Builder().store(uint: 0xc4, bits: 8).store(uint: 18, bits: 32).endCell()
        let withReference = try Builder().store(uint: 0xc4, bits: 8).store(uint: 18, bits: 32).store(uint: 0, bits: 64).store(ref: Builder()).endCell()
        for cell in [wrongTag, short, withReference] {
            XCTAssertThrowsError(try TOSNetworkIdentity.decodeVMVersion(["config": ["bytes": try cell.toBoc().base64EncodedString()]]))
        }
        XCTAssertThrowsError(try TOSNetworkIdentity.decodeVMVersion([:]))
    }

    func testReadsSignedNetworkIDFromCanonicalConfig19Cell() throws {
        for value in [Int32.min, -239, 0, 3, Int32.max] {
            let cell = try Builder().store(int: value, bits: 32).endCell()
            let result: [String: Any] = ["config": ["bytes": try cell.toBoc().base64EncodedString()]]
            XCTAssertEqual(try TOSNetworkIdentity.decodeConfiguration(result), value)
        }
    }

    func testUnknownOrMalformedNetworkIdentityFailsClosed() throws {
        let reference = try Builder().store(int: 3, bits: 32).store(ref: Builder()).endCell()
        let extraBits = try Builder().store(int: 3, bits: 32).store(bit: false).endCell()
        let responses: [[String: Any]] = [[:], ["global_id": 3], ["config": ["bytes": "invalid"]], ["config": ["bytes": try reference.toBoc().base64EncodedString()]], ["config": ["bytes": try extraBits.toBoc().base64EncodedString()]]]
        for result in responses {
            XCTAssertThrowsError(try TOSNetworkIdentity.decodeConfiguration(result))
        }
    }
    func testOnlyUninitializedAccountsMayDefaultToZeroSequence() throws {
        XCTAssertEqual(try TOSWalletRPC.decodeSeqno(["account_state": "uninitialized", "seqno": NSNull(), "wallet": false]), 0)
        XCTAssertEqual(try TOSWalletRPC.decodeSeqno(["account_state": "active", "seqno": UInt32.max, "wallet": true]), UInt32.max)
        let invalid: [Any] = [NSNull(), true, -1, 4_294_967_296 as UInt64, 1.5, "garbage"]
        for value in invalid {
            XCTAssertThrowsError(try TOSWalletRPC.decodeSeqno(["account_state": "active", "seqno": value, "wallet": true]))
        }
        XCTAssertThrowsError(try TOSWalletRPC.decodeSeqno(["seqno": 0]))
    }

    func testJSONFeeAndSequenceNumbersRejectFloatingStorageAndOverflow() throws {
        for token in ["9007199254740992.5", "18446744073709551616", "1.5", "-1", "true"] {
            let json = "{\"source_fees\":{\"in_fwd_fee\":\(token),\"storage_fee\":0,\"gas_fee\":0,\"fwd_fee\":0}}"
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertThrowsError(try TOSWalletRPC.decodeFees(response), "Malformed JSON fee token: \(token)")
        }
        for token in ["4294967295.0000001", "1.5", "4294967296", "true"] {
            let json = "{\"account_state\":\"active\",\"wallet\":true,\"seqno\":\(token)}"
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertThrowsError(try TOSWalletRPC.decodeSeqno(response), "Malformed JSON sequence token: \(token)")
        }
        XCTAssertEqual(try TOSWalletRPC.decodeFees(["source_fees": ["in_fwd_fee": String(UInt64.max), "storage_fee": "0", "gas_fee": "0", "fwd_fee": "0"]]), UInt64.max)
        XCTAssertThrowsError(try TOSWalletRPC.decodeFees(["source_fees": ["in_fwd_fee": String(UInt64.max), "storage_fee": "1", "gas_fee": "0", "fwd_fee": "0"]]))
        XCTAssertThrowsError(try TOSWalletRPC.decodeFees(["source_fees": ["in_fwd_fee": NSNumber(value: 2.0), "storage_fee": 0, "gas_fee": 0, "fwd_fee": 0]]))
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("{\"source_fees\":{\"in_fwd_fee\":1,\"storage_fee\":2,\"gas_fee\":3,\"fwd_fee\":4}}".utf8)) as? [String: Any])
        XCTAssertEqual(try TOSWalletRPC.decodeFees(valid), 10)
    }

}
