import XCTest
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSQuantumAuthTests: XCTestCase {
    private func hash(_ value: UInt8) -> Data { var d = Data(count: 32); d[31] = value; return d }
    private func request(_ role: TOSQuantumRole, _ action: TOSQuantumAction? = nil) throws -> TOSQuantumAuth {
        try TOSQuantumAuth(globalId: 42, network: hash(123), wallet: Address(workchain: 0, hash: hash(100)),
            module: Address(workchain: 0, hash: hash(101)), role: role, epoch: 1, nonce: 0, validUntil: 1780000600,
            action: action ?? .execute(Builder().endCell()), provenTime: 1780000000)
    }
    private func send(_ mode: UInt8, previous: Cell? = nil, tag: UInt32 = 0x0ec3c86d) throws -> Cell {
        try Builder().store(uint: tag, bits: 32).store(uint: mode, bits: 8)
            .store(ref: previous ?? Builder().endCell()).store(ref: Builder().endCell()).endCell()
    }
    func testIndependentPrimaryAndRescueWireVectors() throws {
        let vectors: [(TOSQuantumRole, String, String)] = [
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
            if allowed.contains(mode) { XCTAssertNoThrow(try TOSQuantumAuth.validateActions(actions)) }
            else { XCTAssertThrowsError(try TOSQuantumAuth.validateActions(actions)) }
        }
        XCTAssertThrowsError(try TOSQuantumAuth.validateActions(send(3, previous: send(32))))
        var list = try Builder().endCell()
        for count in 0...256 {
            if count <= 255 { XCTAssertNoThrow(try TOSQuantumAuth.validateActions(list)) }
            else { XCTAssertThrowsError(try TOSQuantumAuth.validateActions(list)) }
            list = try send(3, previous: list)
        }
        XCTAssertThrowsError(try TOSQuantumAuth.validateActions(send(3, tag: 0xad4de08e)))
    }
    func testPrimaryControlsAndClassicalSignatureRefused() throws {
        let empty = try Builder().endCell()
        for action in [TOSQuantumAction.configure(replacement: nil), .lockPrimary,
                       .migrate(moduleInit: empty, metadata: empty, vaultInit: empty)] {
            XCTAssertThrowsError(try request(.primary, action))
            XCTAssertNoThrow(try request(.rescue, action))
        }
        for role in [TOSQuantumRole.primary, .rescue] {
            let r = try request(role)
            for count in [64, role.signatureSize - 1, role.signatureSize + 1] {
                XCTAssertThrowsError(try r.submission(signature: Data(count: count)))
            }
        }
    }
    func testAllIndependentActionVectors() throws {
        func tag(_ n: UInt8) throws -> Cell { try Builder().store(uint: n, bits: 8).endCell() }
        do {
            let r = try request(.primary, .execute(Builder().endCell()))
            XCTAssertEqual(r.request.hash(), Data(hex: "117829e21b72b6e2041f15c92b4b1276ef05ccf5a90fe4f1fa65de76c16f2a19"))
            XCTAssertEqual(r.digest, Data(hex: "b42018426236198dd5be93d0300bcaf161d29c1b22727951e2891f5d6b019eec"))
            XCTAssertEqual(try r.submission(signature: Data(repeating: 0xa5, count: r.role.signatureSize)).hash(), Data(hex: "80f53e05a27dbb286952aa8a23c134a2daa0cea93f64285fdd931b5db92e89d2"))
        }
        do {
            let r = try request(.rescue, .execute(Builder().endCell()))
            XCTAssertEqual(r.request.hash(), Data(hex: "4525eb377a604bd438d0e5d7233ea52de59c0c13eebea823c6926f784aad4eba"))
            XCTAssertEqual(r.digest, Data(hex: "de815703739699e50580272c84495b7964faf411d50dc03db79e48230e3e18a8"))
            XCTAssertEqual(try r.submission(signature: Data(repeating: 0xa5, count: r.role.signatureSize)).hash(), Data(hex: "60fb1d06134c90f95acc876ab25ea3fd391abc731e23527744bc7128d617e57f"))
        }
        do {
            let r = try request(.rescue, .configure(replacement: nil))
            XCTAssertEqual(r.request.hash(), Data(hex: "8478f4270ceb1ce10c7332073178519962d17b634acacd9f3e58191d3b6a501e"))
            XCTAssertEqual(r.digest, Data(hex: "e2a61220523035e212549a1ee678ba9b61de25c582328e8a89eed97cfc2a3e0b"))
            XCTAssertEqual(try r.submission(signature: Data(repeating: 0xa5, count: r.role.signatureSize)).hash(), Data(hex: "e972db3559cc28c274d4bf1b7dbb249aa7c603adfb1bbed01d59300f10b459b9"))
        }
        do {
            let r = try request(.rescue, .configure(replacement: (metadata: tag(1), vaultInit: tag(2))))
            XCTAssertEqual(r.request.hash(), Data(hex: "4217b0148d1199ebb9ac1a4fdcf5bb63d3abd4f24d245ea89192a68d7257d47e"))
            XCTAssertEqual(r.digest, Data(hex: "6ae034de5cae60c1bda9ca1d72ecfdddf70f6fad20736d0ebef05c2c053adddf"))
            XCTAssertEqual(try r.submission(signature: Data(repeating: 0xa5, count: r.role.signatureSize)).hash(), Data(hex: "414d363db59bdbb6145cc138dbd9d2e7fc731bb08a7638effa68348d2937ea40"))
        }
        do {
            let r = try request(.rescue, .lockPrimary)
            XCTAssertEqual(r.request.hash(), Data(hex: "19b4696476903df28fae6e810cd21bdf043c0b332f6bfa5ff9fcb3c101a8aa86"))
            XCTAssertEqual(r.digest, Data(hex: "e57eeede14e3f2e78753c017661c59de915c9e94b0d28da9ef5d58881fae4327"))
            XCTAssertEqual(try r.submission(signature: Data(repeating: 0xa5, count: r.role.signatureSize)).hash(), Data(hex: "86595892c9af65a91f2db90912c68004f9c36dee36beb5029ff73824938323a4"))
        }
        do {
            let r = try request(.rescue, .migrate(moduleInit: tag(1), metadata: tag(2), vaultInit: tag(3)))
            XCTAssertEqual(r.request.hash(), Data(hex: "f4d8f32b1bcb1f2ed8e2e6956cfd40870492df9a04584a27a3eb7577f7d9a6bc"))
            XCTAssertEqual(r.digest, Data(hex: "d060c9abb3a571cee1fe2121676d8cb394e61c7a59ced5ac01d7cd1aa2ae5e08"))
            XCTAssertEqual(try r.submission(signature: Data(repeating: 0xa5, count: r.role.signatureSize)).hash(), Data(hex: "91517376b5dda01ee0e144073eb1c4f46aa88762a04484a1058ecff6926f00ab"))
        }
    }
}
