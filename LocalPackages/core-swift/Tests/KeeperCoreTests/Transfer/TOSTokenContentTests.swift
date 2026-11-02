import Foundation
import CryptoKit
import BigInt
@testable import KeeperCore
import TonSwift
import XCTest

final class TOSTokenContentTests: XCTestCase {
    private func fixture(_ name: String) throws -> Cell {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "boc", subdirectory: "quantum-payment"))
        return try XCTUnwrap(Cell.fromBoc(src: Data(contentsOf: url)).first)
    }
    private func snake(_ text: String) throws -> Cell { try Builder().store(uint: 0, bits: 8).store(data: Data(text.utf8)).endCell() }
    private func metadata(_ field: String, value: Cell) throws -> Cell {
        let key = Data(SHA256.hash(data: Data(field.utf8)))
        let root = try Builder().store(uint: 2, bits: 2).store(uint: 256, bits: 9).store(data: key).store(ref: value).endCell()
        return try Builder().store(uint: 0, bits: 8).store(bit: true).store(ref: root).endCell()
    }
    func testIndependentFiftContentPreservesFieldsAndUnresolvedURI() throws {
        let local = try TOSTokenContent.decode(fixture("token-content-onchain"))
        XCTAssertEqual(local.name, "Sample Credit"); XCTAssertEqual(local.symbol, "CR"); XCTAssertEqual(local.decimals, 6); XCTAssertNil(local.uri)
        let remote = try TOSTokenContent.decode(fixture("token-content-uri"))
        XCTAssertEqual(remote.uri, "https://example.invalid/token.json"); XCTAssertNil(remote.decimals)
        XCTAssertNil(remote.name); XCTAssertNil(remote.symbol)
    }
    func testPrecisionIsBoundedAndEmptyOnchainDictionaryDefaultsToNine() throws {
        XCTAssertEqual(try TOSTokenContent.decode(Builder().store(uint: 0, bits: 8).store(bit: false).endCell()).decimals, 9)
        for value in ["0", "6", "09", "18", "255"] {
            XCTAssertEqual(try TOSTokenContent.decode(metadata("decimals", value: snake(value))).decimals, Int(value))
        }
        for value in ["-1", "+1", "256", "1e2", "6.0", " 6", "١"] {
            XCTAssertThrowsError(try TOSTokenContent.decode(metadata("decimals", value: snake(value))), value)
        }
        XCTAssertNil(try TOSTokenContent.decode(metadata("uri", value: snake("https://example.invalid/hybrid.json"))).decimals)
    }
    func testMalformedUTF8TrailingDataAndOversizedOrDeepSnakesAreRefused() throws {
        let empty = try Builder().endCell()
        var deep = try Builder().store(data: Data("https://example.invalid/deep.json".utf8)).endCell()
        for _ in 0..<256 { deep = try Builder().store(ref: deep).endCell() }
        var oversized: Cell?, bytes = Data(repeating: 65, count: 2049)
        while !bytes.isEmpty {
            let count = min(127, bytes.count), b = try Builder().store(data: Data(bytes.suffix(min(127, bytes.count))))
            if let oversized { try b.store(ref: oversized) }
            oversized = try b.endCell(); bytes.removeLast(count)
        }
        let invalid: [Cell] = [
            try Builder().store(uint: 2, bits: 8).endCell(),
            try Builder().store(uint: 0, bits: 8).store(bit: false).store(bit: false).endCell(),
            try Builder().store(uint: 1, bits: 8).store(data: Data([255])).endCell(),
            try Builder().store(uint: 1, bits: 8).store(ref: empty).store(ref: empty).endCell(),
            try Builder().store(uint: 1, bits: 8).store(ref: XCTUnwrap(oversized)).endCell(),
            try Builder().store(uint: 1, bits: 8).store(ref: deep).endCell()]
        for value in invalid { XCTAssertThrowsError(try TOSTokenContent.decode(value)) }
    }
    func testDictionaryLengthAndUTF8SplitAcrossSnakeCellsAreChecked() throws {
        let malformed = try Builder().store(uint: 2, bits: 2).store(uint: 257, bits: 9).endCell()
        XCTAssertThrowsError(try TOSTokenContent.decode(Builder().store(uint: 0, bits: 8).store(bit: true).store(ref: malformed).endCell()))
        let tail = try Builder().store(data: Data([0x95, 0x8c])).endCell()
        let value = try Builder().store(uint: 0, bits: 8).store(data: Data([0xe7])).store(ref: tail).endCell()
        XCTAssertEqual(try TOSTokenContent.decode(metadata("name", value: value)).name, "界")
    }
    func testRepeatedBitDictionaryLabelsDoNotConsumeLiteralBits() throws {
        let key = Data(SHA256.hash(data: Data("decimals".utf8))), value = try snake("6")
        let tail = try Builder().store(data: key).endCell().beginParse(); try tail.skip(2)
        let leaf = try Builder().store(uint: 2, bits: 2).store(uint: 254, bits: 8).store(slice: tail).store(ref: value).endCell()
        let dummy = try Builder().store(uint: 2, bits: 2).store(uint: 254, bits: 8).store(biguint: 0, bits: 254).store(ref: value).endCell()
        let root = try Builder().store(uint: 3, bits: 2).store(bit: key[0] & 128 != 0).store(uint: 1, bits: 9)
        if key[0] & 64 != 0 { try root.store(ref: dummy).store(ref: leaf) }
        else { try root.store(ref: leaf).store(ref: dummy) }
        XCTAssertEqual(try TOSTokenContent.decode(Builder().store(uint: 0, bits: 8).store(bit: true).store(ref: root.endCell()).endCell()).decimals, 6)
    }
}
