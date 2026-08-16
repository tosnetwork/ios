import Foundation
import XCTest
@testable import TKAgentCommerce

final class PurchaseJournalTests: XCTestCase {
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() { lock.withLock { value += 1 } }
        func read() -> Int { lock.withLock { value } }
    }

    func testLeaseIsPersistedBeforeFundingAndCannotBeReacquiredAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TKAgentCommerce-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let journal = try PurchaseJournal(directory: root)
        XCTAssertEqual(try journal.create(purchaseID: "purchase_01", nowUnix: 10).phase, "intent")
        XCTAssertEqual(try journal.advance(to: "prepared", nowUnix: 11).phase, "prepared")
        let leased = try journal.acquireFundingLease(id: "lease_01", nowUnix: 12)
        XCTAssertEqual(leased.phase, "funding_lease")
        XCTAssertEqual(try journal.resumeAction(), .reconcileNeverRefund)

        let restarted = try PurchaseJournal(directory: root)
        XCTAssertEqual(try restarted.load(), leased)
        XCTAssertEqual(try restarted.resumeAction(), .reconcileNeverRefund)
        XCTAssertThrowsError(try restarted.acquireFundingLease(id: "lease_02", nowUnix: 13))
        XCTAssertEqual(try restarted.advance(to: "funded", nowUnix: 14).phase, "funded")
    }

    func testCannotSkipOrMoveBackwardAcrossFundingLease() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TKAgentCommerce-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try PurchaseJournal(directory: root)
        _ = try journal.create(purchaseID: "purchase_02", nowUnix: 10)
        XCTAssertThrowsError(try journal.advance(to: "funded", nowUnix: 11))
        _ = try journal.advance(to: "prepared", nowUnix: 12)
        _ = try journal.acquireFundingLease(id: "lease_02", nowUnix: 13)
        XCTAssertThrowsError(try journal.advance(to: "prepared", nowUnix: 14))
    }

    func testConcurrentInstancesGrantExactlyOneLease() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TKAgentCommerce-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = try PurchaseJournal(directory: root)
        _ = try setup.create(purchaseID: "purchase_03", nowUnix: 10)
        _ = try setup.advance(to: "prepared", nowUnix: 11)

        let journals = [try PurchaseJournal(directory: root), try PurchaseJournal(directory: root)]
        let successes = LockedCounter()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            if (try? journals[index].acquireFundingLease(id: "lease_0\(index)", nowUnix: 12)) != nil {
                successes.increment()
            }
        }
        XCTAssertEqual(successes.read(), 1)
        XCTAssertEqual(try setup.resumeAction(), .reconcileNeverRefund)
    }
}
