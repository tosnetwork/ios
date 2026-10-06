import XCTest
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSV5R2AuthTests: XCTestCase {
    private func hash(_ value: UInt8) -> Data { var d = Data(count: 32); d[31] = value; return d }
    private func request(_ role: TOSV5R2Role, _ action: TOSV5R2Action? = nil) throws -> TOSV5R2Auth {
        try TOSV5R2Auth(globalId: 42, network: hash(123), wallet: Address(workchain: 0, hash: hash(100)),
            module: Address(workchain: 0, hash: hash(101)), role: role, epoch: 1, nonce: 0, validUntil: 1780000600,
            action: action ?? .execute(Builder().endCell()), provenTime: 1780000000)
    }
    private func send(_ mode: UInt8, previous: Cell? = nil, tag: UInt32 = 0x0ec3c86d) throws -> Cell {
        try Builder().store(uint: tag, bits: 32).store(uint: mode, bits: 8)
            .store(ref: previous ?? Builder().endCell()).store(ref: Builder().endCell()).endCell()
    }
    func testIndependentPrimaryAndRescueWireVectors() throws {
        let vectors: [(TOSV5R2Role, String, String)] = [
            (.primary, "b42018426236198dd5be93d0300bcaf161d29c1b22727951e2891f5d6b019eec", "80f53e05a27dbb286952aa8a23c134a2daa0cea93f64285fdd931b5db92e89d2"),
            (.rescue, "de815703739699e50580272c84495b7964faf411d50dc03db79e48230e3e18a8", "60fb1d06134c90f95acc876ab25ea3fd391abc731e23527744bc7128d617e57f")
        ]
        for (role, digest, envelope) in vectors {
            let r = try request(role)
            XCTAssertEqual(r.digest, Data(hex: digest))
            XCTAssertEqual(try r.submission(signature: Data(repeating: 0xa5, count: role.signatureSize)).hash(), Data(hex: envelope))
        }
    }
    func testAllSendModesAndCompleteListBoundaries() throws {
        let allowed: Set<UInt8> = [2, 3, 18, 19, 66, 67, 82, 83, 130, 131, 146, 147]
        for mode in UInt8.min...UInt8.max {
            let actions = try send(mode)
            if allowed.contains(mode) { XCTAssertNoThrow(try TOSV5R2Auth.validateActions(actions)) }
            else { XCTAssertThrowsError(try TOSV5R2Auth.validateActions(actions)) }
        }
        XCTAssertThrowsError(try TOSV5R2Auth.validateActions(send(3, previous: send(32))))
        var list = try Builder().endCell()
        for count in 0...256 {
            if count <= 255 { XCTAssertNoThrow(try TOSV5R2Auth.validateActions(list)) }
            else { XCTAssertThrowsError(try TOSV5R2Auth.validateActions(list)) }
            list = try send(3, previous: list)
        }
        XCTAssertThrowsError(try TOSV5R2Auth.validateActions(send(3, tag: 0xad4de08e)))
    }
    func testPrimaryControlsAndClassicalSignatureRefused() throws {
        let empty = try Builder().endCell()
        for action in [TOSV5R2Action.configure(replacement: nil), .lockPrimary,
                       .migrate(moduleInit: empty, metadata: empty, vaultInit: empty)] {
            XCTAssertThrowsError(try request(.primary, action))
            XCTAssertNoThrow(try request(.rescue, action))
        }
        for role in [TOSV5R2Role.primary, .rescue] {
            let r = try request(role)
            for count in [64, role.signatureSize - 1, role.signatureSize + 1] {
                XCTAssertThrowsError(try r.submission(signature: Data(count: count)))
            }
        }
    }
}
