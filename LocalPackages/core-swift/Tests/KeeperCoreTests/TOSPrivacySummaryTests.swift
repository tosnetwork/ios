import CoreComponents
import Foundation
import XCTest

final class TOSPrivacySummaryTests: XCTestCase {
    private enum RecheckFailure: Error { case stale }

    private func fixture() throws -> (Data, [Data]) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "privacy-session", withExtension: "json"))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return (try JSONSerialization.data(withJSONObject: XCTUnwrap(value["request"])),
                try XCTUnwrap(value["transactions"] as? [String]).map { try XCTUnwrap(Data(base64Encoded: $0)) })
    }

    private static func completed(request: Data, transactions: [Data]) throws -> TOSPrivacyHistoryWalk.Completed {
        var cursor = transactions.count - 1
        return try TOSPrivacyHistoryWalk.replay(request: request, query: { _, _, _ in
            guard cursor >= 0 else { throw TOSPrivacyHistoryWalk.Failure.incomplete }
            defer { cursor -= 1 }; return transactions[cursor]
        }, recheck: {})
    }

    func testReadySummaryReturnsOnlyCompletePublicFieldsAndWipesSeed() async throws {
        let (request, transactions) = try fixture()
        try await Task.detached {
            let completed = try Self.completed(request: request, transactions: transactions)
            defer { completed.close() }
            var seed = Data(repeating: 0x42, count: 32), checks = 0
            let result = try completed.summaryAndWipeSeed(seed: &seed, stopped: { false }, recheck: { checks += 1 })
            XCTAssertEqual(seed, Data(repeating: 0, count: 32)); XCTAssertEqual(checks, 2)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
            XCTAssertEqual(Set(value.keys), Set(["version", "total_outputs", "owned_outputs", "unique_unspent_notes",
                "duplicate_outputs", "reused_indices_count", "diagnostics_count", "unspent_balance", "scan_next_index"]))
            XCTAssertEqual(value["version"] as? Int, 1)
            XCTAssertEqual(value["total_outputs"] as? String, "13")
            let owned = try XCTUnwrap(UInt64(try XCTUnwrap(value["owned_outputs"] as? String)))
            XCTAssertLessThanOrEqual(owned, 13)
            let balance = try XCTUnwrap(value["unspent_balance"] as? String)
            XCTAssertFalse(balance.isEmpty); XCTAssertTrue(balance.utf8.allSatisfy { (48...57).contains($0) })
            completed.close()
            seed = Data(repeating: 0x42, count: 32)
            XCTAssertThrowsError(try completed.summaryAndWipeSeed(seed: &seed, stopped: { false }, recheck: {}))
            XCTAssertEqual(seed, Data(repeating: 0, count: 32))
        }.value
    }

    func testNativeSummaryRefusesUnfinishedClosedAndInvalidSeedOwners() async throws {
        let (request, transactions) = try fixture()
        try await Task.detached {
            let replay = try TOSPrivacyNative.Replay(request: request)
            defer { replay.close() }
            var seed = Data(repeating: 0x42, count: 32)
            XCTAssertThrowsError(try replay.summaryAndWipeSeed(seed: &seed, stopped: { false }))
            XCTAssertEqual(seed, Data(repeating: 0, count: 32))
            for transaction in transactions { try replay.push(boc: transaction) }
            try replay.finish()
            seed = Data(repeating: 0x42, count: 31)
            XCTAssertThrowsError(try replay.summaryAndWipeSeed(seed: &seed, stopped: { false }))
            XCTAssertEqual(seed, Data(repeating: 0, count: 31))
            seed = Data(repeating: 0x42, count: 32)
            _ = try replay.summaryAndWipeSeed(seed: &seed, stopped: { false })
            XCTAssertEqual(seed, Data(repeating: 0, count: 32))
            replay.close()
            seed = Data(repeating: 0x42, count: 32)
            XCTAssertThrowsError(try replay.summaryAndWipeSeed(seed: &seed, stopped: { false }))
            XCTAssertEqual(seed, Data(repeating: 0, count: 32))
        }.value
    }

    func testCompletedSummaryRejectsBothFailedProofRechecksAndCancellation() async throws {
        let (request, transactions) = try fixture()
        try await Task.detached {
            for failedCheck in [1, 2] {
                let completed = try Self.completed(request: request, transactions: transactions)
                defer { completed.close() }
                var seed = Data(repeating: 0x42, count: 32), checks = 0
                XCTAssertThrowsError(try completed.summaryAndWipeSeed(seed: &seed, stopped: { false }, recheck: {
                    checks += 1
                    if checks == failedCheck { throw RecheckFailure.stale }
                })) { error in
                    guard case RecheckFailure.stale = error else { return XCTFail("Expected proof recheck refusal") }
                }
                XCTAssertEqual(checks, failedCheck); XCTAssertEqual(seed, Data(repeating: 0, count: 32))
            }
            let completed = try Self.completed(request: request, transactions: transactions)
            defer { completed.close() }
            var seed = Data(repeating: 0x42, count: 32), checks = 0
            XCTAssertThrowsError(try completed.summaryAndWipeSeed(seed: &seed, stopped: { true }, recheck: { checks += 1 }))
            XCTAssertEqual(checks, 0); XCTAssertEqual(seed, Data(repeating: 0, count: 32))
            var cancelled = false
            seed = Data(repeating: 0x42, count: 32)
            XCTAssertThrowsError(try completed.summaryAndWipeSeed(seed: &seed, stopped: { cancelled }, recheck: {
                checks += 1
                if checks == 2 { cancelled = true }
            }))
            XCTAssertEqual(checks, 2); XCTAssertEqual(seed, Data(repeating: 0, count: 32))
        }.value
    }

    func testNativeSummaryRejectsCancellationAfterItsSerializedCall() async throws {
        let (request, transactions) = try fixture()
        try await Task.detached {
            let replay = try TOSPrivacyNative.Replay(request: request)
            defer { replay.close() }
            for transaction in transactions { try replay.push(boc: transaction) }
            try replay.finish()
            var seed = Data(repeating: 0x42, count: 32), polls = 0
            XCTAssertThrowsError(try replay.summaryAndWipeSeed(seed: &seed, stopped: {
                polls += 1; return polls == 3
            })) { error in
                guard case TOSPrivacyNative.Failure.stopped = error else { return XCTFail("Expected late cancellation") }
            }
            XCTAssertEqual(polls, 3); XCTAssertEqual(seed, Data(repeating: 0, count: 32))
        }.value
    }

    @MainActor
    func testNativeSummaryRequiresWorkerAndWipesSeedOnMainThread() throws {
        let (request, _) = try fixture()
        let replay = try TOSPrivacyNative.Replay(request: request)
        defer { replay.close() }
        var seed = Data(repeating: 0x42, count: 32)
        XCTAssertThrowsError(try replay.summaryAndWipeSeed(seed: &seed, stopped: { false })) { error in
            guard case TOSPrivacyNative.Failure.requiresWorker = error else { return XCTFail("Expected worker requirement") }
        }
        XCTAssertEqual(seed, Data(repeating: 0, count: 32))
    }
}
