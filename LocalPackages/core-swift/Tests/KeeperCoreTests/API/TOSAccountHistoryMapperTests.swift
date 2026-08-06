@testable import KeeperCore
import TonSwift
import XCTest

final class TOSAccountHistoryMapperTests: XCTestCase {
    private let subject = try! Address.parse("0:" + String(repeating: "11", count: 32))
    private let counterparty = "0:" + String(repeating: "22", count: 32)

    func testMapsIncomingAndOutgoingNativeTOSTransfers() throws {
        let events = try TOSAccountHistoryMapper.events([
            fixture(id: "200:aa", direction: "incoming", amount: "1250000000", bounced: false),
            fixture(id: "100:bb", direction: "outgoing", amount: "500000000", bounced: true),
        ], account: subject)

        XCTAssertEqual(events.map(\.eventId), ["200:aa", "100:bb"])
        XCTAssertEqual(events[0].date.timeIntervalSince1970, 1_700_000_000)
        guard case let .Fee(fee) = events[0].extra else { return XCTFail("Expected fee") }
        XCTAssertEqual(fee, 42)

        guard case let .tonTransfer(incoming) = events[0].actions.first?.type else {
            return XCTFail("Expected incoming native TOS transfer")
        }
        XCTAssertEqual(incoming.amount, 1_250_000_000)
        XCTAssertEqual(incoming.sender.address.toRaw(), counterparty)
        XCTAssertEqual(incoming.recipient.address, subject)
        XCTAssertNil(incoming.comment)
        XCTAssertNil(events[0].actions.first?.status.rawValue)

        guard case let .tonTransfer(outgoing) = events[1].actions.first?.type else {
            return XCTFail("Expected outgoing native TOS transfer")
        }
        XCTAssertEqual(outgoing.sender.address, subject)
        XCTAssertEqual(outgoing.recipient.address.toRaw(), counterparty)
        XCTAssertNotNil(events[1].actions.first?.status.rawValue)
    }

    func testMapsEmptyHistory() throws {
        XCTAssertTrue(try TOSAccountHistoryMapper.events([], account: subject).isEmpty)
    }

    func testRejectsMalformedEventAndTransfer() {
        XCTAssertThrowsError(try TOSAccountHistoryMapper.events([["event_id": "missing-fields"]], account: subject))
        XCTAssertThrowsError(try TOSAccountHistoryMapper.events([
            fixture(id: "1:cc", direction: "jetton", amount: "1", bounced: false),
        ], account: subject))
    }

    private func fixture(id: String, direction: String, amount: String, bounced: Bool) -> [String: Any] {
        let subjectRaw = subject.toRaw()
        return [
            "event_id": id,
            "timestamp": 1_700_000_000,
            "fee": "42",
            "transfers": [[
                "direction": direction,
                "source": direction == "incoming" ? counterparty : subjectRaw,
                "destination": direction == "incoming" ? subjectRaw : counterparty,
                "amount": amount,
                "bounced": bounced,
            ]],
        ]
    }
}
