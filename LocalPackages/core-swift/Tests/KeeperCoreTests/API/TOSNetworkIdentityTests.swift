@testable import KeeperCore
import TonSwift
import XCTest

final class TOSNetworkIdentityTests: XCTestCase {
    func testNativeWalletVMCapabilityBoundaryAndCanonicalConfig8() throws {
        for version in [UInt32(0), 3, 4, 5, 6, 18, UInt32.max] {
            let cell = try Builder().store(uint: 0xc4, bits: 8).store(uint: version, bits: 32).store(uint: 0x1ee, bits: 64).endCell()
            for encoded in try TOSRPCBOCTestFixtures.encodedForms(cell) {
                let result: [String: Any] = ["config": ["bytes": encoded]]
                let decoded = try TOSNetworkIdentity.decodeVMVersion(result)
                XCTAssertEqual(decoded, version)
                if version < 6 {
                    XCTAssertThrowsError(try TOSNetworkIdentity.requireWalletVMVersion(decoded))
                } else {
                    XCTAssertNoThrow(try TOSNetworkIdentity.requireWalletVMVersion(decoded))
                }
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
            for encoded in try TOSRPCBOCTestFixtures.encodedForms(cell) {
                let result: [String: Any] = ["config": ["bytes": encoded]]
                XCTAssertEqual(try TOSNetworkIdentity.decodeConfiguration(result), value)
            }
        }
    }

    func testUnknownOrMalformedNetworkIdentityFailsClosed() throws {
        let reference = try Builder().store(int: 3, bits: 32).store(ref: Builder()).endCell()
        let extraBits = try Builder().store(int: 3, bits: 32).store(bit: false).endCell()
        let responses: [[String: Any]] = [[:], ["global_id": 3], ["config": ["bytes": "invalid"]], ["config": ["bytes": try reference.toBoc().base64EncodedString()]], ["config": ["bytes": try extraBits.toBoc().base64EncodedString()]]]
        for result in responses {
            XCTAssertThrowsError(try TOSNetworkIdentity.decodeConfiguration(result))
        }
        for encoded in try TOSRPCBOCTestFixtures.malformedBase64() {
            XCTAssertThrowsError(try TOSRPCOrdinaryBOC.decode(encoded))
            let result: [String: Any] = ["config": ["bytes": encoded]]
            XCTAssertThrowsError(try TOSNetworkIdentity.decodeConfiguration(result)) { error in
                guard case TOSNetworkIdentityError.invalidConfiguration = error else {
                    return XCTFail("Expected invalidConfiguration, got \(error)")
                }
            }
            XCTAssertThrowsError(try TOSNetworkIdentity.decodeVMVersion(result)) { error in
                guard case TOSNetworkIdentityError.invalidConfiguration = error else {
                    return XCTFail("Expected invalidConfiguration, got \(error)")
                }
            }
        }
        XCTAssertNoThrow(try TOSRPCOrdinaryBOC.decode(TOSRPCBOCTestFixtures.chain(depth: 1_023).base64EncodedString()))
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

// PUBLIC TEST DATA. Malformed byte strings are deliberately constructed without
// the SDK serializer/parser so the regression reaches the untrusted RPC boundary.
enum TOSRPCBOCTestFixtures {
    static func malformedBase64() throws -> [String] {
        let hex = [
            "b5ee9c7201010001000000", // zero cells
            "b5ee9c72010101000002000000", // zero roots
            "b5ee9c72010102020004000100000000", // multiple roots
            "b5ee9c72010101010002010000", // root outside cell table
            "b5ee9c7201010101000300010001", // reference outside cell table
            "b5ee9c7201010101000300010000", // self reference
            "b5ee9c7201010201000600010001010000", // backward/cyclic reference
            "b5ee9c720101020100040000000000", // unreachable extra cell
            "b5ee9c720101010100070005000000000000", // five references
            "b5ee9c7201010101000300000100", // missing top-up marker
            "b5ee9c7201010101000300000180", // noncanonical empty partial byte
            "b5ee9c72010101010003000000", // truncated cell bytes
            "b5ee9c72410101010002000000", // truncated CRC
            "b5ee9c724101010100020000004cacb900", // incorrect CRC
            "b5ee9c7201010101000200000000", // trailing bytes
            "b5ee9c72000101010002000000", // zero size width
            "b5ee9c72050101010002000000", // unsupported size width
            "b5ee9c72010001010002000000", // zero offset width
            "b5ee9c72010501010002000000", // unsupported offset width
            "b5ee9c72010101010102000000", // absent cells
            "b5ee9c72090101010002000000", // reserved flags
            "b5ee9c72210101010002000000", // cache-bit flag
            "b5ee9c72010101010002001000", // stored cell hashes
            "b5ee9c72010101010002002000", // nonzero cell level
            "b5ee9c7281010101000200010000", // invalid index offset
            "b5ee9c720202400100010000000200000000", // excessive cell count
            "68ff65f3010101010002000000", // unsupported older BOC magic
        ]
        var values = try hex.map { try XCTUnwrap(Data(hex: $0)).base64EncodedString() }
        values.append(chain(depth: 1_024).base64EncodedString())
        values.append(Data(repeating: 0, count: 1_048_577).base64EncodedString())
        return values
    }

    static func encodedForms(_ cell: Cell) throws -> [String] {
        // Config8/19 are single reference-free cells with one-byte widths.
        // The pinned serializer writes start offsets; the equivalent end-index
        // representation is assembled explicitly and carries no CRC to update.
        var endIndexed = try cell.toBoc(idx: true, crc32: false)
        guard endIndexed.count >= 14, endIndexed[4] == 0x81,
              endIndexed[5] == 1, endIndexed[6] == 1, cell.refs.isEmpty else {
            throw TOSRPCClient.Error.invalidResponse
        }
        endIndexed[11] = endIndexed[9]
        let forms = [
            try cell.toBoc(idx: false, crc32: false),
            try cell.toBoc(idx: false, crc32: true),
            try cell.toBoc(idx: true, crc32: true),
            endIndexed,
        ]
        return forms.map { $0.base64EncodedString() }
    }

    static func chain(depth: Int) -> Data {
        // A root-first forward-reference chain. Two-byte widths are sufficient
        // for these public 1023/1024 boundary samples.
        var bytes: [UInt8] = [0xb5, 0xee, 0x9c, 0x72, 2, 2]
        for value in [depth + 1, 1, 0, depth * 4 + 2, 0] {
            bytes.append(UInt8((value >> 8) & 0xff))
            bytes.append(UInt8(value & 0xff))
        }
        for parent in 0..<depth {
            let child = parent + 1
            bytes += [1, 0, UInt8((child >> 8) & 0xff), UInt8(child & 0xff)]
        }
        bytes += [0, 0]
        return Data(bytes)
    }
}
