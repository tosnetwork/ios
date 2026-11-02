import XCTest
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSQuantumSelfPayNetworkTests: XCTestCase {
    private let network = Data(repeating: 0x42, count: 32)
    private func version(_ value: UInt32 = 16, tag: UInt8 = 0xc4, tail: Bool = false) throws -> Cell {
        let b = try Builder().store(uint: tag, bits: 8).store(uint: value, bits: 32).store(uint: 0, bits: 64)
        if tail { try b.store(bit: false) }
        return try b.endCell()
    }
    private func identity(_ value: Int32 = 1, tail: Bool = false) throws -> Cell {
        let b = try Builder().store(int: value, bits: 32)
        if tail { try b.store(bit: false) }
        return try b.endCell()
    }
    private func policy(retired: UInt16 = 0, deadline: UInt32? = nil, validSpec: Bool = true) throws -> Cell {
        let text = "5e4380aedc95f8cb72de55f7506de0269b47c03ad1d1ed0e5184c332544262c0"
        let spec = Data(stride(from: 0, to: text.count, by: 2).map { offset in
            let start = text.index(text.startIndex, offsetBy: offset)
            return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
        })
        let b = try Builder().store(uint: 0xa1, bits: 8).store(data: network)
            .store(uint: 0, bits: 64).store(uint: retired, bits: 16)
        if let deadline {
            let schedule = try Builder().store(uint: 2, bits: 2).store(uint: 8, bits: 4)
                .store(uint: 1, bits: 8).store(uint: deadline, bits: 32).endCell()
            try b.store(bit: true).store(ref: schedule)
        } else { try b.store(bit: false) }
        return try b.store(data: validSpec ? spec : Data(count: 32)).endCell()
    }

    func testNetworkSchemaAndSignedGlobalID() throws {
        for globalID: Int32 in [1, -1, Int32.min, Int32.max] {
            XCTAssertEqual(try TOSQuantumSelfPayNetwork.validate(version: version(), identity: identity(globalID),
                policy: policy(), expectedGlobalID: globalID, now: 100), network)
        }
    }

    func testCreationRequiresVM16AndExactConfigShapes() throws {
        for v in try [version(15), version(tag: 0xc5), version(tail: true)] {
            XCTAssertThrowsError(try TOSQuantumSelfPayNetwork.validate(version: v, identity: identity(),
                policy: policy(), expectedGlobalID: 1, now: 100))
        }
        for i in try [identity(2), identity(tail: true)] {
            XCTAssertThrowsError(try TOSQuantumSelfPayNetwork.validate(version: version(), identity: i,
                policy: policy(), expectedGlobalID: 1, now: 100))
        }
    }

    func testCreationRequiresEligiblePrimaryAndKnownPolicy() throws {
        for p in try [policy(retired: 2), policy(retired: 4), policy(validSpec: false), policy(deadline: 100)] {
            XCTAssertThrowsError(try TOSQuantumSelfPayNetwork.validate(version: version(), identity: identity(),
                policy: p, expectedGlobalID: 1, now: 100))
        }
        XCTAssertEqual(try TOSQuantumSelfPayNetwork.validate(version: version(), identity: identity(),
            policy: policy(deadline: 101), expectedGlobalID: 1, now: 100), network)
    }

    func testBootstrapRequestRequiresBoundedFreshness() throws {
        for age: Int64 in [0, -1, 3600, Int64.max] {
            XCTAssertThrowsError(try TOSQuantumSelfPayNetwork.request(maximumAge: age))
        }
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with:
            TOSQuantumSelfPayNetwork.request(maximumAge: 300)) as? [String: Any])
        XCTAssertEqual(request["config_params"] as? [Int], [8, 19, 48])
        XCTAssertEqual(request["mode"] as? String, "live")
        XCTAssertEqual(request["max_age_seconds"] as? Int, 300)
    }
}
