import Foundation
@testable import KeeperCore
import TonSwift
import XCTest

final class TOSWalletTransactionCursorTests: XCTestCase {
    func testAcceptsActualUninitializedZeroCursorAndInt64Boundary() throws {
        let zero = try TOSWalletTransactionCursor.decode(response(lt: "0", hash: Data(repeating: 0, count: 32).base64EncodedString()))
        XCTAssertEqual(zero.lt, 0)
        XCTAssertEqual(zero.txHash, String(repeating: "0", count: 64))
        let maximum = try TOSWalletTransactionCursor.decode(response(lt: String(Int64.max), hash: Data(repeating: 255, count: 32).base64EncodedString()))
        XCTAssertEqual(maximum.lt, Int64.max)
        XCTAssertEqual(maximum.txHash, String(repeating: "f", count: 64))
    }

    func testRejectsMissingNonDecimalNegativeAndOverflowLogicalTimes() {
        let hash = Data(repeating: 0, count: 32).base64EncodedString()
        let invalidTimes: [Any] = [NSNull(), true, 0, "", "-1", "+1", " 1", "1.0", "١", "9223372036854775808"]
        for lt in invalidTimes {
            XCTAssertThrowsError(try TOSWalletTransactionCursor.decode(response(lt: lt, hash: hash)))
        }
        XCTAssertThrowsError(try TOSWalletTransactionCursor.decode([:]))
        XCTAssertThrowsError(try TOSWalletTransactionCursor.decode(["last_transaction_id": ["hash": hash]]))
    }

    func testRejectsMissingMalformedNonCanonicalAndWrongLengthHashes() {
        let valid = Data(repeating: 0, count: 32).base64EncodedString()
        let invalidHashes: [Any] = [NSNull(), 0, "", "not-base64", valid + "\n", String(valid.dropLast()), Data(repeating: 0, count: 31).base64EncodedString(), Data(repeating: 0, count: 33).base64EncodedString()]
        for hash in invalidHashes {
            XCTAssertThrowsError(try TOSWalletTransactionCursor.decode(response(lt: "0", hash: hash)))
        }
        XCTAssertThrowsError(try TOSWalletTransactionCursor.decode(["last_transaction_id": ["lt": "0"]]))
    }

    private func response(lt: Any, hash: Any) -> [String: Any] {
        ["last_transaction_id": ["lt": lt, "hash": hash]]
    }
}

final class WalletBackgroundUpdatePollingTests: XCTestCase {
    func testInitialReadAndCursorChangesRefreshWithoutHealthyDuplicates() async throws {
        let first = try makeCursor(lt: 1, byte: 1)
        let sameLTNewHash = try makeCursor(lt: 1, byte: 2)
        let next = try makeCursor(lt: 2, byte: 3)
        let events = expectation(description: "Initial read and both cursor changes")
        events.expectedFulfillmentCount = 3
        let sixReads = expectation(description: "Unchanged healthy snapshots were polled")
        let script = CursorSnapshotScript(steps: [.success(first), .success(first), .success(sameLTNewHash), .success(sameLTNewHash), .success(next), .success(next)]) {
            if $0 == 6 { sixReads.fulfill() }
        }
        let recorder = CursorUpdateRecorder()
        let updater = makeUpdater { try await script.next() }
        updater.eventClosure = { event in
            recorder.record(event)
            events.fulfill()
        }
        defer { updater.stop() }
        updater.start()
        await fulfillment(of: [events, sixReads], timeout: 2)
        updater.stop()
        XCTAssertEqual(recorder.events.map(\.lt), [1, 1, 2])
        XCTAssertEqual(recorder.events.map(\.txHash), [first.txHash, sameLTNewHash.txHash, next.txHash])
    }

    func testStopAndResumeRefreshEvenWhenCursorIsUnchanged() async throws {
        let cursor = try makeCursor(lt: 1, byte: 1)
        let first = expectation(description: "Initial refresh")
        let resumed = expectation(description: "Resume refresh")
        let recorder = CursorUpdateRecorder()
        let updater = makeUpdater { cursor }
        updater.eventClosure = { event in
            recorder.record(event)
            switch recorder.events.count {
            case 1: first.fulfill()
            case 2: resumed.fulfill()
            default: XCTFail("Unchanged healthy cursor emitted another refresh")
            }
        }
        defer { updater.stop() }
        updater.start()
        await fulfillment(of: [first], timeout: 2)
        updater.stop()
        updater.start()
        await fulfillment(of: [resumed], timeout: 2)
        updater.stop()
        XCTAssertEqual(recorder.events.map(\.lt), [1, 1])
    }

    func testReadFailureRecoversAndRefreshesOnceForSameCursor() async throws {
        let cursor = try makeCursor(lt: 1, byte: 1)
        let events = expectation(description: "Initial and recovery refreshes")
        events.expectedFulfillmentCount = 2
        let fourReads = expectation(description: "Recovered unchanged snapshot checked")
        let script = CursorSnapshotScript(steps: [.success(cursor), .failure(URLError(.notConnectedToInternet)), .success(cursor), .success(cursor)]) {
            if $0 == 4 { fourReads.fulfill() }
        }
        let recorder = CursorUpdateRecorder()
        let updater = makeUpdater { try await script.next() }
        updater.stateClosure = { recorder.record($0) }
        updater.eventClosure = {
            recorder.record($0)
            events.fulfill()
        }
        defer { updater.stop() }
        updater.start()
        await fulfillment(of: [events, fourReads], timeout: 2)
        updater.stop()
        XCTAssertEqual(recorder.events.map(\.lt), [1, 1])
        XCTAssertEqual(recorder.states, [.connected, .noConnection, .connected])
    }

    func testStopDiscardsAnUncooperativeInFlightRead() async throws {
        let started = expectation(description: "Read started")
        let lateEvent = expectation(description: "Stopped request must not deliver")
        lateEvent.isInverted = true
        let gate = PendingCursorSnapshots(started: [started])
        let updater = makeUpdater(pollIntervalNanoseconds: 60_000_000_000) { await gate.next() }
        updater.eventClosure = { _ in lateEvent.fulfill() }
        updater.start()
        await fulfillment(of: [started], timeout: 2)
        updater.stop()
        await gate.complete(0, with: try makeCursor(lt: 9, byte: 9))
        await fulfillment(of: [lateEvent], timeout: 0.05)
        let requests = await gate.requestCount
        XCTAssertEqual(requests, 1)
    }

    func testRestartDiscardsOldResponseAndDeliversCurrentGeneration() async throws {
        let firstRead = expectation(description: "Old read started")
        let currentRead = expectation(description: "Current read started")
        let currentEvent = expectation(description: "Current generation refresh")
        let gate = PendingCursorSnapshots(started: [firstRead, currentRead])
        let recorder = CursorUpdateRecorder()
        let updater = makeUpdater(pollIntervalNanoseconds: 60_000_000_000) { await gate.next() }
        updater.eventClosure = { event in
            recorder.record(event)
            currentEvent.fulfill()
        }
        defer { updater.stop() }
        updater.start()
        await fulfillment(of: [firstRead], timeout: 2)
        updater.start()
        await fulfillment(of: [currentRead], timeout: 2)
        await gate.complete(0, with: try makeCursor(lt: 9, byte: 9))
        await gate.complete(1, with: try makeCursor(lt: 10, byte: 10))
        await fulfillment(of: [currentEvent], timeout: 2)
        updater.stop()
        XCTAssertEqual(recorder.events.map(\.lt), [10])
    }

    private func makeUpdater(pollIntervalNanoseconds: UInt64 = 2_000_000, snapshot: @escaping () async throws -> TOSWalletTransactionCursor) -> WalletBackgroundUpdate {
        WalletBackgroundUpdate(wallet: cursorFixtureWallet(), snapshot: snapshot, pollIntervalNanoseconds: pollIntervalNanoseconds)
    }

    private func makeCursor(lt: Int64, byte: UInt8) throws -> TOSWalletTransactionCursor {
        try TOSWalletTransactionCursor.decode(["last_transaction_id": ["lt": String(lt), "hash": Data(repeating: byte, count: 32).base64EncodedString()]])
    }
}

private actor CursorSnapshotScript {
    private var steps: [Result<TOSWalletTransactionCursor, Swift.Error>]
    private var last: Result<TOSWalletTransactionCursor, Swift.Error>
    private var calls = 0
    private let onCall: (Int) -> Void

    init(steps: [Result<TOSWalletTransactionCursor, Swift.Error>], onCall: @escaping (Int) -> Void) {
        precondition(!steps.isEmpty)
        self.steps = steps
        self.last = steps[0]
        self.onCall = onCall
    }

    func next() throws -> TOSWalletTransactionCursor {
        calls += 1
        if !steps.isEmpty { last = steps.removeFirst() }
        onCall(calls)
        return try last.get()
    }
}

private actor PendingCursorSnapshots {
    private let started: [XCTestExpectation]
    private var continuations = [Int: CheckedContinuation<TOSWalletTransactionCursor, Never>]()
    private(set) var requestCount = 0

    init(started: [XCTestExpectation]) {
        self.started = started
    }

    func next() async -> TOSWalletTransactionCursor {
        let index = requestCount
        requestCount += 1
        return await withCheckedContinuation { continuation in
            continuations[index] = continuation
            if index < started.count { started[index].fulfill() }
        }
    }

    func complete(_ index: Int, with cursor: TOSWalletTransactionCursor) {
        continuations.removeValue(forKey: index)?.resume(returning: cursor)
    }
}

private final class CursorUpdateRecorder {
    private let lock = NSLock()
    private var storedEvents = [BackgroundUpdateEvent]()
    private var storedStates = [BackgroundUpdateConnectionState]()

    var events: [BackgroundUpdateEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    var states: [BackgroundUpdateConnectionState] {
        lock.lock()
        defer { lock.unlock() }
        return storedStates
    }

    func record(_ event: BackgroundUpdateEvent) {
        lock.lock()
        defer { lock.unlock() }
        storedEvents.append(event)
    }

    func record(_ state: BackgroundUpdateConnectionState) {
        lock.lock()
        defer { lock.unlock() }
        storedStates.append(state)
    }
}

private func cursorFixtureWallet(globalID: Int32 = 3) -> Wallet {
    Wallet(id: "background-cursor-fixture", identity: WalletIdentity(network: .mainnet, kind: .Regular(PublicKey(data: Data(repeating: 0, count: 32)), .tosV5R1), networkGlobalId: globalID), metaData: WalletMetaData(label: "Fixture", tintColor: .defaultColor, icon: .icon(.wallet)), setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
}
