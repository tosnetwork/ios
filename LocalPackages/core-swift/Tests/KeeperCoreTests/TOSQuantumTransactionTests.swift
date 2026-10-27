import XCTest
import Foundation
import BigInt
import TonSwift
import CoreComponents
import CryptoKit
@testable import KeeperCore

private extension Builder {
    @discardableResult
    func store(varuint amount: BigUInt, limit: Int) throws -> Self {
        let size = (amount.bitWidth + 7) / 8
        guard limit > 1, size < limit else { throw TOSPQError.invalidInput }
        try store(uint: size, bits: Int.bitWidth - (limit - 1).leadingZeroBitCount)
        if size != 0 { try store(biguint: amount, bits: size * 8) }
        return self
    }
}

final class TOSQuantumTransactionTests: XCTestCase {
    private let sender = Address(workchain: 0, hash: Data(repeating: 0x55, count: 32))
    private let recipient = Address(workchain: 0, hash: Data(repeating: 0x66, count: 32))

    func testFrozenNativeHistoryAcceptsOpaqueBodiesWithoutInventingTransfers() throws {
        let manifest = try XCTUnwrap(Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "quantum-transactions"))
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let rows = try XCTUnwrap(data["transactions"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        let account = try Address.parse("0:" + XCTUnwrap(data["account"] as? String))
        var payloads = [UInt64: String](), expectedTimes = [UInt64]()
        for (index, row) in rows.enumerated() {
            let file = try XCTUnwrap(row["file"] as? String)
            XCTAssertEqual(file, "transaction-\(index).boc")
            let bytes = try Data(contentsOf: manifest.deletingLastPathComponent().appendingPathComponent(file))
            let fileDigest = CryptoKit.SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(fileDigest, row["sha256"] as? String)
            let hash = try XCTUnwrap(Data(hex: XCTUnwrap(row["hash"] as? String)))
            let time = try XCTUnwrap(UInt64(XCTUnwrap(row["lt"] as? String)))
            let encoded = bytes.base64EncodedString()
            let value = try TOSQuantumTransaction(encoded: encoded, expectedHash: hash, expectedLogicalTime: time, address: account)
            XCTAssertEqual(value.outbound.compactMap { $0.amount?.description }, row["outgoing_amounts"] as? [String])
            XCTAssertEqual(value.action?.skipped, UInt64(try XCTUnwrap(row["skipped_actions"] as? Int)))
            if index == 0 {
                XCTAssertThrowsError(try TOSRPCOrdinaryBOC.decode(encoded))
                XCTAssertTrue(value.successfulExecution)
                XCTAssertTrue(value.outbound.isEmpty)
                XCTAssertFalse(value.matchesOutgoingTransfer(externalHash: try XCTUnwrap(value.inbound).hash,
                    sender: account, recipient: recipient, amount: 10_000_000_000, bodyHash: Data(repeating: 0, count: 32)))
            }
            payloads[time] = encoded; expectedTimes.append(time)
        }
        let head = try XCTUnwrap(Data(hex: XCTUnwrap(data["proven_head"] as? String)))
        var queried = [UInt64]()
        let page = try TOSQuantumHistoryReader.walk(address: account, logicalTime: XCTUnwrap(expectedTimes.first), hash: head,
            limit: 20, query: { _, time, _ in queried.append(time); return try XCTUnwrap(payloads[time]) })
        XCTAssertEqual(queried, expectedTimes)
        XCTAssertEqual(page.transactions.count, 3)
        XCTAssertFalse(page.hasMore)
    }

    private func body() throws -> Cell { try Builder().store(uint: 0, bits: 32).store(data: Data("Payment".utf8)).endCell() }
    private func external() throws -> Cell {
        try Builder().store(uint: 8, bits: 4).store(sender).store(varuint: 0, limit: 16)
            .store(bit: false).store(bit: true).store(ref: body()).endCell()
    }
    private func internalMessage(amount: BigUInt, to: Address? = nil) throws -> Cell {
        try Builder().store(uint: 4, bits: 4).store(sender).store(to ?? recipient)
            .store(varuint: amount, limit: 16).store(bit: false).store(varuint: 0, limit: 16)
            .store(varuint: 0, limit: 16).store(uint: 123, bits: 64).store(uint: 1_793_000_000, bits: 32)
            .store(bit: false).store(bit: true).store(ref: body()).endCell()
    }
    private struct Key: Hashable, CellCodable, StaticSize {
        static let bitWidth = 15
        let value: UInt16
        static func loadFrom(slice: Slice) throws -> Self { Self(value: UInt16(try slice.loadUint(bits: 15))) }
        func storeTo(builder: Builder) throws { try builder.store(uint: value, bits: 15) }
    }
    private func transaction(logicalTime: UInt64 = 1_000, previous: (UInt64, Data)? = nil,
                             incoming: Cell? = nil, outgoing: [Cell] = [], successful: Bool = true,
                             skipped: UInt16 = 0, fees: BigUInt = 1_000_000,
                             outputKey: UInt16? = nil, trailing: Bool = false) throws -> Cell {
        let vm = try Builder().store(varuint: 10_000, limit: 7).store(varuint: 1_000_000, limit: 7)
            .store(bit: true).store(varuint: 10_000, limit: 3).store(int: 0, bits: 8)
            .store(int: successful ? 0 : 13, bits: 32).store(bit: false).store(uint: 123, bits: 32)
            .store(data: Data(repeating: 0, count: 64)).endCell()
        let action = try Builder().store(bit: successful).store(bit: true).store(bit: false).store(bit: false)
            .store(bit: false).store(bit: false).store(int: successful ? 0 : 42, bits: 32).store(bit: false)
            .store(uint: outgoing.count + Int(skipped), bits: 16).store(uint: 0, bits: 16)
            .store(uint: skipped, bits: 16).store(uint: outgoing.count, bits: 16)
            .store(data: Data(repeating: 0, count: 32)).store(varuint: 1, limit: 7).store(varuint: 100, limit: 7).endCell()
        let description = try Builder().store(uint: 0, bits: 4).store(bit: false)
            .store(bit: false).store(bit: false).store(bit: true).store(bit: successful)
            .store(bit: false).store(bit: false).store(varuint: 1_000_000, limit: 16).store(ref: vm)
            .store(bit: true).store(ref: action).store(bit: !successful).store(bit: false).store(bit: false).endCell()
        let outputs = Dictionary(uniqueKeysWithValues: outgoing.enumerated().map {
            (Key(value: outputKey ?? UInt16($0.offset)), $0.element)
        })
        let messages = Builder()
        try messages.store(bit: incoming != nil)
        if let incoming { try messages.store(ref: incoming) }
        try messages.store(dict: outputs)
        let update = try Builder().store(uint: 0x72, bits: 8).store(data: Data(repeating: 0, count: 64)).endCell()
        let tx = try Builder().store(uint: 7, bits: 4).store(data: sender.hash).store(uint: logicalTime, bits: 64)
            .store(data: previous?.1 ?? Data(repeating: 0, count: 32)).store(uint: previous?.0 ?? 0, bits: 64)
            .store(uint: 1_793_000_000, bits: 32).store(uint: outgoing.count, bits: 15)
            .store(uint: 2, bits: 2).store(uint: 2, bits: 2).store(ref: messages.endCell())
            .store(varuint: fees, limit: 16).store(bit: false).store(ref: update).store(ref: description)
        if trailing { try tx.store(bit: true) }
        return try tx.endCell()
    }
    private func decode(_ cell: Cell, time: UInt64 = 1_000) throws -> TOSQuantumTransaction {
        try TOSQuantumTransaction(encoded: cell.toBoc().base64EncodedString(), expectedHash: cell.hash(),
                                  expectedLogicalTime: time, address: sender)
    }

    func testOnlyCommittedOutgoingMessageMatchesTransferAndPreservesWideAmounts() throws {
        let amount = (BigUInt(1) << 100) + 17, fees = (BigUInt(1) << 90) + 3
        let incoming = try external()
        let cell = try transaction(incoming: incoming, outgoing: [internalMessage(amount: amount)], fees: fees)
        let value = try decode(cell)
        XCTAssertEqual(value.fees, fees)
        XCTAssertEqual(value.outbound.count, 1)
        XCTAssertTrue(value.matchesOutgoingTransfer(externalHash: incoming.hash(), sender: sender, recipient: recipient,
                                         amount: amount, bodyHash: try body().hash()))
        XCTAssertFalse(value.matchesOutgoingTransfer(externalHash: Data(repeating: 9, count: 32), sender: sender, recipient: recipient,
                                          amount: amount, bodyHash: try body().hash()))
        XCTAssertFalse(value.matchesOutgoingTransfer(externalHash: incoming.hash(), sender: sender, recipient: sender,
                                          amount: amount, bodyHash: try body().hash()))
        XCTAssertFalse(value.matchesOutgoingTransfer(externalHash: incoming.hash(), sender: sender, recipient: recipient,
                                          amount: amount - 1, bodyHash: try body().hash()))
        XCTAssertFalse(value.matchesOutgoingTransfer(externalHash: incoming.hash(), sender: sender, recipient: recipient,
                                          amount: amount, bodyHash: Data(repeating: 0, count: 32)))
    }

    func testSuccessfulComputeWithSkippedSendAndFailedExecutionAreNotPaymentReceipts() throws {
        let incoming = try external()
        let skipped = try decode(transaction(incoming: incoming, skipped: 1))
        XCTAssertTrue(skipped.successfulExecution)
        XCTAssertEqual(skipped.action?.skipped, 1)
        XCTAssertFalse(skipped.matchesOutgoingTransfer(externalHash: incoming.hash(), sender: sender, recipient: recipient,
                                            amount: 10, bodyHash: try body().hash()))
        let failed = try decode(transaction(incoming: incoming, outgoing: [internalMessage(amount: 10)], successful: false))
        XCTAssertFalse(failed.successfulExecution)
        XCTAssertFalse(failed.matchesOutgoingTransfer(externalHash: incoming.hash(), sender: sender, recipient: recipient,
                                           amount: 10, bodyHash: try body().hash()))
    }

    func testUntrustedHashAddressLogicalTimeAndMalformedLayoutsFailClosed() throws {
        let cell = try transaction()
        let encoded = try cell.toBoc().base64EncodedString()
        XCTAssertThrowsError(try TOSQuantumTransaction(encoded: encoded, expectedHash: Data(repeating: 0, count: 32),
                                                      expectedLogicalTime: 1_000, address: sender))
        XCTAssertThrowsError(try TOSQuantumTransaction(encoded: encoded, expectedHash: cell.hash(),
                                                      expectedLogicalTime: 999, address: sender))
        XCTAssertThrowsError(try TOSQuantumTransaction(encoded: encoded, expectedHash: cell.hash(),
                                                      expectedLogicalTime: 1_000, address: recipient))
        XCTAssertThrowsError(try decode(transaction(previous: (1_000, Data(repeating: 1, count: 32)))))
        XCTAssertThrowsError(try decode(transaction(previous: (1, Data(repeating: 0, count: 32)))))
        XCTAssertThrowsError(try decode(transaction(outgoing: [internalMessage(amount: 1)], outputKey: 2)))
        XCTAssertThrowsError(try decode(transaction(trailing: true)))
    }

    func testHashChainWalkIsBoundedAndRetainsUnsigned64BitLogicalTimes() throws {
        let oldTime = UInt64.max - 2, newTime = UInt64.max - 1
        let old = try transaction(logicalTime: oldTime)
        let new = try transaction(logicalTime: newTime, previous: (oldTime, old.hash()))
        var times = [UInt64]()
        let query: TOSQuantumHistoryReader.Query = { address, time, hash in
            XCTAssertEqual(address, self.sender.toRaw()); times.append(time)
            let cell = time == newTime ? new : old
            XCTAssertEqual(hash, cell.hash())
            return try cell.toBoc().base64EncodedString()
        }
        let one = try TOSQuantumHistoryReader.walk(address: sender, logicalTime: newTime, hash: new.hash(), limit: 1, query: query)
        XCTAssertEqual(one.transactions.count, 1); XCTAssertTrue(one.hasMore); XCTAssertEqual(times, [newTime])
        times = []
        let all = try TOSQuantumHistoryReader.walk(address: sender, logicalTime: newTime, hash: new.hash(), limit: 20, query: query)
        XCTAssertEqual(times, [newTime, oldTime]); XCTAssertFalse(all.hasMore)
        let empty = try TOSQuantumHistoryReader.walk(address: sender, logicalTime: 0, hash: Data(repeating: 0, count: 32),
                                                    limit: 20, query: { _, _, _ in XCTFail("Absent account queried history"); return "" })
        XCTAssertTrue(empty.transactions.isEmpty); XCTAssertFalse(empty.hasMore)
        XCTAssertThrowsError(try TOSQuantumHistoryReader.walk(address: sender, logicalTime: newTime, hash: new.hash(), limit: 21, query: query))
        XCTAssertThrowsError(try TOSQuantumHistoryReader.walk(address: sender, logicalTime: newTime, hash: new.hash(), limit: 20,
            query: { _, _, _ in try old.toBoc().base64EncodedString() }))
        XCTAssertThrowsError(try TOSQuantumHistoryReader.walk(address: sender, logicalTime: newTime, hash: new.hash(), limit: 20,
            query: query, stopped: { true }))
    }
}
