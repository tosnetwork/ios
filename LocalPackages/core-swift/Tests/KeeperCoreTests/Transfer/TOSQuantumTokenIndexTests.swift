import Foundation
import CoreComponents
@testable import KeeperCore
import XCTest

final class TOSQuantumTokenIndexTests: XCTestCase {
    private var row: [String: String] { ["token_master": "0:" + String(repeating: "22", count: 32), "token_wallet": "0:" + String(repeating: "11", count: 32)] }
    private func index(_ rows: [[String: String]], state: [String: Any] = [:]) -> [String: Any] {
        ["@type": "wallet.accountTokens", "tokens": rows, "index_state": state]
    }
    func testHintsRetainExplicitlyUntrustedReadinessAndOwnershipFlags() throws {
        let result = try TOSQuantumTokenIndex.decode(index([row], state: ["complete": true]))
        XCTAssertEqual(result.positions.first, .init(wallet: row["token_wallet"]!, master: row["token_master"]!))
        XCTAssertTrue(result.nodeReportsComplete); XCTAssertFalse(result.reachedRowLimit)
        XCTAssertFalse(try TOSQuantumTokenIndex.decode(index([])).nodeReportsComplete)
        XCTAssertFalse(try TOSQuantumTokenIndex.decode(index([], state: ["complete": true, "ownership_complete": false])).nodeReportsComplete)
        XCTAssertFalse(try TOSQuantumTokenIndex.decode(index([], state: ["complete": 1])).nodeReportsComplete)
    }
    func testMalformedOrDuplicateRowsAreRefused() {
        XCTAssertThrowsError(try TOSQuantumTokenIndex.decode(index([row, row])))
        XCTAssertThrowsError(try TOSQuantumTokenIndex.decode(index([["token_master": row["token_master"]!, "token_wallet": "0:wrong"]])))
        XCTAssertThrowsError(try TOSQuantumTokenIndex.decode(index([["token_master": row["token_master"]!]])))
        XCTAssertThrowsError(try TOSQuantumTokenIndex.decode(["@type": "wallet.accountTokens", "tokens": NSNull()]))
    }
    func testRowLimitIsExplicitAndExcessRowsAreRejected() throws {
        var rows = (0..<10_000).map { ["token_master": String(format: "0:%064x", $0 + 1), "token_wallet": String(format: "0:%064x", $0 + 10_001)] }
        let value = try TOSQuantumTokenIndex.decode(index(rows))
        XCTAssertEqual(value.positions.count, 10_000); XCTAssertTrue(value.reachedRowLimit)
        rows.append(["token_master": String(format: "0:%064x", 10_001), "token_wallet": String(format: "0:%064x", 20_001)])
        XCTAssertThrowsError(try TOSQuantumTokenIndex.decode(index(rows)))
    }
}
