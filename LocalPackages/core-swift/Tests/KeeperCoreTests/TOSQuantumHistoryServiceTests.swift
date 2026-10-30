import XCTest
import Foundation
import CryptoKit
import CoreComponents
import TonSwift
import BigInt
@testable import KeeperCore

final class TOSQuantumHistoryServiceTests: XCTestCase {
    private func digest(_ value: String) throws -> Data {
        guard value.count == 64 else { throw TOSPQError.invalidInput }
        return try Data(stride(from: 0, to: value.count, by: 2).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            return try XCTUnwrap(UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16))
        })
    }

    func testUninitializedIncomingTransfersAreIncludedDespiteSkippedCompute() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "incoming-manifest", withExtension: "json", subdirectory: "quantum-transactions"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let account = try XCTUnwrap(manifest["account"] as? String), address = try Address.parse(account)
        let rows = try XCTUnwrap(manifest["transactions"] as? [[String: Any]])
        var hash = try digest(XCTUnwrap(manifest["proven_head"] as? String))
        var time = try XCTUnwrap(UInt64(XCTUnwrap(manifest["proven_lt"] as? String)))
        var fees = [String]()
        for row in rows {
            let file = try XCTUnwrap(row["file"] as? String)
            let bytes = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(file))
            XCTAssertEqual(CryptoKit.SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), row["sha256"] as? String)
            let transaction = try TOSQuantumTransaction(encoded: bytes.base64EncodedString(), expectedHash: hash,
                expectedLogicalTime: time, address: address)
            XCTAssertTrue(transaction.aborted)
            XCTAssertFalse(transaction.computeSuccess)
            let record = TOSQuantumHistoryRecord(transaction, account: account)
            XCTAssertEqual(record.direction, .incoming)
            XCTAssertEqual(record.outcome, .included)
            XCTAssertEqual(record.inbound?.amountNano, "10000000000")
            XCTAssertTrue(record.outbound.isEmpty)
            fees.append(record.feesNano)
            hash = transaction.previousHash; time = transaction.previousLogicalTime
        }
        XCTAssertEqual(fees, ["1", "0"])
        XCTAssertEqual(time, 0); XCTAssertEqual(hash, Data(repeating: 0, count: 32))
    }

    func testSkippedExternalRequestCannotBecomeOutgoingTransfer() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "quantum-transactions"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let account = "0:" + (try XCTUnwrap(manifest["account"] as? String))
        let rows = try XCTUnwrap(manifest["transactions"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first), file = try XCTUnwrap(row["file"] as? String)
        let transaction = try TOSQuantumTransaction(encoded: Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(file)).base64EncodedString(),
            expectedHash: digest(XCTUnwrap(row["hash"] as? String)),
            expectedLogicalTime: XCTUnwrap(UInt64(XCTUnwrap(row["lt"] as? String))), address: Address.parse(account))
        let record = TOSQuantumHistoryRecord(transaction, account: account)
        XCTAssertEqual(record.direction, .operation)
        XCTAssertEqual(record.outcome, .sendSkipped)
        XCTAssertEqual(record.skippedActions, 1)
        XCTAssertTrue(record.outbound.isEmpty)
    }

    func testNanoFormattingPreservesExactWideValuesAndRejectsInvalidCoins() {
        XCTAssertEqual(TOSQuantumHistoryRecord.formatNano("0"), "0 TOS")
        XCTAssertEqual(TOSQuantumHistoryRecord.formatNano("1"), "0.000000001 TOS")
        XCTAssertEqual(TOSQuantumHistoryRecord.formatNano("10000000000"), "10 TOS")
        XCTAssertEqual(TOSQuantumHistoryRecord.formatNano("1267650600228229401496703205393"), "1267650600228229401496.703205393 TOS")
        for invalid in ["", "01", "-1", "1.0", "١", (BigUInt(1) << 120).description] {
            XCTAssertNil(TOSQuantumHistoryRecord.formatNano(invalid))
        }
    }
}
