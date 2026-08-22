import BigInt
@testable import KeeperCore
import TonSwift
import XCTest

final class TOSDNSOperationTests: XCTestCase {
    func testRegistrationBodyUsesOpZeroSnakeEncoding() throws {
        let label = String(repeating: "a", count: 126)
        let body = try TOSDNSOperation.register(label: label).body()
        let slice = try body.beginParse()
        XCTAssertEqual(try slice.loadUint(bits: 32), 0)
        var bytes = try slice.loadBytes(slice.remainingBits / 8)
        if slice.remainingRefs == 1 {
            let tail = try slice.loadRef().beginParse()
            bytes.append(try tail.loadBytes(tail.remainingBits / 8))
        }
        XCTAssertEqual(String(data: bytes, encoding: .utf8), label)
    }

    func testRegistrationRejectsContractInvalidLabels() {
        for label in ["abc", "-abcd", "abcd-", "Abcd", "a_bcd", String(repeating: "a", count: 127)] {
            XCTAssertThrowsError(try TOSDNSOperation.register(label: label).body(), label)
        }
        XCTAssertNoThrow(try TOSDNSOperation.register(label: "a--b").body())
        XCTAssertNoThrow(try TOSDNSOperation.register(label: "xn--80ak6aa92e").body())
    }

    func testBidBodyIsEmpty() throws {
        let slice = try TOSDNSOperation.bidOrTopUp.body().beginParse()
        XCTAssertEqual(slice.remainingBits, 0)
        XCTAssertEqual(slice.remainingRefs, 0)
    }

    func testFinishAndReleaseBodiesMatchTIP1() throws {
        var slice = try TOSDNSOperation.finishAuction(queryId: 7).body().beginParse()
        XCTAssertEqual(try slice.loadUint(bits: 32), 0x2fcb26a2)
        XCTAssertEqual(try slice.loadUint(bits: 64), 7)
        XCTAssertEqual(slice.remainingBits, 0)

        slice = try TOSDNSOperation.release(queryId: 9).body().beginParse()
        XCTAssertEqual(try slice.loadUint(bits: 32), 0x4ed14b65)
        XCTAssertEqual(try slice.loadUint(bits: 64), 9)
        XCTAssertEqual(slice.remainingBits, 0)
    }

    func testRecordSetAndDeleteEncoding() throws {
        let value = try Builder().store(uint: 0x9fd3, bits: 16).endCell()
        var slice = try TOSDNSOperation.changeRecord(category: 42, value: value, queryId: 11).body().beginParse()
        XCTAssertEqual(try slice.loadUint(bits: 32), 0x4eb1f0f9)
        XCTAssertEqual(try slice.loadUint(bits: 64), 11)
        XCTAssertEqual(try slice.loadUint(bits: 256), 42)
        XCTAssertEqual(try slice.loadRef().hash(), value.hash())

        slice = try TOSDNSOperation.changeRecord(category: 42, value: nil, queryId: 12).body().beginParse()
        _ = try slice.loadUint(bits: 32)
        _ = try slice.loadUint(bits: 64)
        _ = try slice.loadUint(bits: 256)
        XCTAssertEqual(slice.remainingRefs, 0)
    }

    func testAuctionRulesMatchCanonicalTIP1Vectors() throws {
        let start = TOSDNSAuctionRules.auctionStartTime
        XCTAssertEqual(try TOSDNSAuctionRules.minimumPrice(labelBytes: 5, now: start + 1), 500_000_000_000)
        XCTAssertEqual(
            try TOSDNSAuctionRules.minimumPrice(labelBytes: 5, now: start + TOSDNSAuctionRules.periodSeconds),
            450_000_000_000
        )
        XCTAssertEqual(TOSDNSAuctionRules.minimumNextBid(100_000_000_001), 105_000_000_001)
    }

    func testManagementPlannerPinsTargetsAndFailsClosed() throws {
        let owner = try Address.parse("0:" + String(repeating: "11", count: 32))
        let collection = try Address.parse("0:" + String(repeating: "22", count: 32))
        let item = try Address.parse("0:" + String(repeating: "33", count: 32))
        let root = try Address.parse("-1:" + String(repeating: "00", count: 32))
        let available = TOSDNSDomainState(
            canonicalName: "alice.tos", label: "alice", rootAddress: root,
            collectionAddress: collection, itemAddress: item, lifecycle: .available,
            ownerAddress: nil, maximumBid: 0, auctionEndTime: 0, renewalDeadline: nil
        )
        let now = TOSDNSAuctionRules.auctionStartTime + 1
        let minimum = try TOSDNSAuctionRules.minimumPrice(labelBytes: 5, now: now)
        let registration = try TOSDNSManagementPlanner.operation(
            state: available, walletAddress: owner, action: .register(bid: minimum), now: now, queryId: 1
        )
        XCTAssertEqual(registration.target, collection)
        XCTAssertThrowsError(try TOSDNSManagementPlanner.operation(
            state: available, walletAddress: owner, action: .register(bid: minimum - 1), now: now, queryId: 1
        ))

        let ended = TOSDNSDomainState(
            canonicalName: "alice.tos", label: "alice", rootAddress: root,
            collectionAddress: collection, itemAddress: item, lifecycle: .auctionEnded,
            ownerAddress: nil, maximumBid: minimum, auctionEndTime: now - 1, renewalDeadline: nil
        )
        let finish = try TOSDNSManagementPlanner.operation(
            state: ended, walletAddress: owner, action: .finishAuction, now: now, queryId: 7
        )
        XCTAssertEqual(finish.target, item)
        XCTAssertThrowsError(try TOSDNSManagementPlanner.operation(
            state: ended, walletAddress: owner, action: .renew(amount: TOSDNSAuctionRules.oneTOS), now: now, queryId: 7
        ))

        let leased = TOSDNSDomainState(
            canonicalName: "alice.tos", label: "alice", rootAddress: root,
            collectionAddress: collection, itemAddress: item, lifecycle: .leased,
            ownerAddress: owner, maximumBid: 0, auctionEndTime: 0,
            renewalDeadline: now + TOSDNSAuctionRules.leaseSeconds
        )
        let renewal = try TOSDNSManagementPlanner.operation(
            state: leased, walletAddress: owner, action: .renew(amount: TOSDNSAuctionRules.oneTOS),
            now: now, queryId: 8
        )
        XCTAssertEqual(renewal.target, item)
        XCTAssertEqual(renewal.amount, TOSDNSAuctionRules.oneTOS)
        let record = try TOSDNSManagementPlanner.operation(
            state: leased, walletAddress: owner, action: .changeRecord(category: 42, value: nil),
            now: now, queryId: 9
        )
        XCTAssertEqual(record.target, item)

        let releasable = TOSDNSDomainState(
            canonicalName: "alice.tos", label: "alice", rootAddress: root,
            collectionAddress: collection, itemAddress: item, lifecycle: .releasable,
            ownerAddress: owner, maximumBid: 0, auctionEndTime: 0, renewalDeadline: now - 1
        )
        let release = try TOSDNSManagementPlanner.operation(
            state: releasable, walletAddress: owner, action: .release(bid: minimum), now: now, queryId: 10
        )
        XCTAssertEqual(release.target, item)
    }

    func testWatchOnlyWalletCannotBuildDNSMutation() throws {
        let wallet = Wallet(
            id: UUID().uuidString,
            identity: .init(
                network: .mainnet,
                kind: .Watchonly(.Resolved(try Address.parse("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c")))
            ),
            metaData: .init(label: "Watch", tintColor: .defaultColor, icon: .icon(.wallet)),
            setupSettings: .init(isSetupFinished: true),
            batterySettings: .init()
        )
        XCTAssertThrowsError(try TOSDNSOperationTransferBuilder.createWalletTransfer(
            wallet: wallet,
            seqno: 0,
            target: try Address.parse("0:" + String(repeating: "11", count: 32)),
            amount: TOSDNSAuctionRules.oneTOS,
            operation: .bidOrTopUp,
            timeout: nil,
            messageType: .ext
        )) { error in
            XCTAssertEqual(error as? TOSDNSOperationError, .watchOnlyWallet)
        }
    }
}
