import XCTest
@testable import KeeperCore

final class TOSPQReceiptTests: XCTestCase {
    func testExactHopReceiptsAndUnknownOrRejectedPayments() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tos-pq-receipt-vectors", withExtension: "json"))
        let f = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let i = try XCTUnwrap(f["intent"] as? [String: Any])
        func text(_ key: String) throws -> String { try XCTUnwrap(i[key] as? String) }
        let intent = try TOSPQPendingOperation(feeAddress: text("feeAddress"), externalHash: text("externalHash"), moduleAddress: text("moduleAddress"), walletAddress: text("walletAddress"), recipient: text("recipient"), amount: 10000000, seqno: 8, expires: 2000000600)
        var map: [String: [[String: Any]]] = [:]
        for (address, key) in [(intent.feeAddress, "fee"), (intent.moduleAddress, "module"), (intent.walletAddress, "wallet"), (intent.recipient!, "recipient")] {
            map[address] = [try XCTUnwrap(f[key] as? [String: Any])]
        }
        func run(_ receipts: [String: [[String: Any]]]) async throws -> TOSPQOperationStatus {
            try await TOSPQReceipt.reconcile(intent, history: { receipts[$0] ?? [] }, deployed: { false })
        }
        let delivered = try await run(map);XCTAssertEqual(delivered, .delivered)
        let pending = try await run([:]);XCTAssertEqual(pending, .pending)
        var numericBoolean = map;var compute = numericBoolean[intent.walletAddress]![0]["compute"] as! [String: Any];compute["success"] = NSNumber(value: 1);numericBoolean[intent.walletAddress]![0]["compute"] = compute
        let malformed = try await run(numericBoolean);XCTAssertEqual(malformed, .authAccepted)
        XCTAssertNil(TOSWalletRPC.unsignedInteger(NSNumber(value: true)))
        XCTAssertNil(TOSWalletRPC.unsignedInteger(NSNumber(value: 1.1)))
        var missing = map;missing[intent.recipient!] = nil
        let waiting = try await run(missing);XCTAssertEqual(waiting, .authAccepted)
        var unrelated = map;unrelated[intent.recipient!]![0]["in_msg_hash"] = "UNRELATED"
        let unknown = try await run(unrelated);XCTAssertEqual(unknown, .authAccepted)
        var rejected = map;rejected[intent.walletAddress]![0]["aborted"] = true;rejected[intent.walletAddress]![0]["out_msgs"] = [[String: Any]]()
        let failed = try await run(rejected);XCTAssertEqual(failed, .failed)
        var forged = map;var outputs = forged[intent.walletAddress]![0]["out_msgs"] as! [[String: Any]];outputs[0]["value"] = "10000001";forged[intent.walletAddress]![0]["out_msgs"] = outputs
        do { _ = try await run(forged);XCTFail("Wrong recipient value accepted") } catch { }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = TOSPQOperationJournal(directory: directory)
        try await journal.write(intent)
        let reloaded = try await TOSPQOperationJournal(directory: directory).read(address: intent.walletAddress)
        XCTAssertEqual(reloaded?.externalHash, intent.externalHash);XCTAssertEqual(reloaded?.status, .pending)
    }
}
