import XCTest
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSV5R2RetirementPolicyTests: XCTestCase {
    private let network = Data(repeating: 1, count: 32)
    private func policy(retired: UInt16 = 0, deadline: UInt32? = nil, suite: UInt8 = 1, short: Bool = false,
                        validSpec: Bool = true, tag: UInt8 = 0xa1, tail: Bool = false) throws -> Cell {
        let text = "5e4380aedc95f8cb72de55f7506de0269b47c03ad1d1ed0e5184c332544262c0"
        let spec = Data(stride(from: 0, to: text.count, by: 2).map { i in
            let start = text.index(text.startIndex, offsetBy: i)
            return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
        })
        let b = try Builder().store(uint: tag, bits: 8).store(data: network).store(uint: 7, bits: 64).store(uint: retired, bits: 16)
        if let deadline {
            let d = Builder()
            if short { try d.store(bit: false); for _ in 0..<8 { try d.store(bit: true) }; try d.store(bit: false) }
            else { try d.store(uint: 2, bits: 2).store(uint: 8, bits: 4) }
            try d.store(uint: suite, bits: 8).store(uint: deadline, bits: 32)
            try b.store(bit: true).store(ref: d.endCell())
        } else { try b.store(bit: false) }
        try b.store(data: validSpec ? spec : Data(count: 32))
        if tail { try b.store(bit: false) }
        return try b.endCell()
    }
    func testAbsentAndLegalLabelsUntilExactRetirementDeadline() throws {
        try TOSV5R2RetirementPolicy.requirePrimary(policy(), network: network, now: 4620)
        for short in [false, true] {
            try TOSV5R2RetirementPolicy.requirePrimary(policy(deadline: 4700, short: short), network: network, now: 4620)
            XCTAssertThrowsError(try TOSV5R2RetirementPolicy.requirePrimary(policy(deadline: 4620, short: short), network: network, now: 4620), "Scheduled retirement ignored")
        }
    }
    func testRetiredUnknownMalformedAndWrongNetworkRefuse() throws {
        for cell in try [policy(retired: 2), policy(retired: 4), policy(deadline: 0), policy(deadline: 4700, suite: 2),
                         policy(validSpec: false), policy(tag: 0xa2), policy(tail: true)] {
            XCTAssertThrowsError(try TOSV5R2RetirementPolicy.requirePrimary(cell, network: network, now: 4620), "Invalid retirement policy accepted")
        }
        XCTAssertThrowsError(try TOSV5R2RetirementPolicy.requirePrimary(policy(), network: Data(count: 32), now: 4620), "Wrong network accepted")
    }
}
