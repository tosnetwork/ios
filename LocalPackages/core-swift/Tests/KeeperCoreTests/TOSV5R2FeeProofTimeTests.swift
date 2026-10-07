import XCTest
@testable import KeeperCore
final class TOSV5R2FeeProofTimeTests: XCTestCase {
    func testFreshSameSlotAndExactAge() throws {
        try TOSV5R2FeeProofTime.check(master: 4610, shard: 4600, now: 4620, maximumAge: 30, epoch0: 1000)
        try TOSV5R2FeeProofTime.check(master: 4600, shard: 4600, now: 4630, maximumAge: 30, epoch0: 1000)
    }
    func testSlotFutureAgeAndEpochBoundariesRefuse() {
        let rows: [[UInt32]] = [[4610,4599,4620,30,1000],[4599,4610,4620,30,1000],
            [4610,4600,4631,30,1000],[4600,4610,4631,30,1000],[4621,4610,4620,30,1000],
            [4610,4621,4620,30,1000],[4620,4620,4620,0,1000],[4620,4620,4620,3600,1000],
            [999,999,999,30,1000],[999,1000,1001,30,1000],[1000,999,1001,30,1000]]
        for r in rows {
            XCTAssertThrowsError(try TOSV5R2FeeProofTime.check(master: r[0], shard: r[1], now: r[2], maximumAge: r[3], epoch0: r[4]), "Unsafe fee time accepted")
        }
    }
}
