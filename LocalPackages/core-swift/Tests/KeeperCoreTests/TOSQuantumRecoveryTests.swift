import XCTest
import Foundation
import BigInt
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSQuantumRecoveryTests: XCTestCase {
    private func hash(_ n: UInt8) -> Data { var d = Data(count: 32); d[31] = n; return d }
    private func binding(_ deadline: UInt32 = 1780000600) -> TOSQuantumRecoveryBinding {
        TOSQuantumRecoveryBinding(globalId: 42, network: hash(123), wallet: Address(workchain: 0, hash: hash(100)), module: Address(workchain: 0, hash: hash(101)), validUntil: deadline)
    }
    private func byte(_ n: UInt8) throws -> Cell { try Builder().store(uint: n, bits: 8).endCell() }
    private let pops: [[String: String]] = [
        ["role": "1", "policy": "1", "request_hash": "e682e38a1b36f00d9966585725ea68ca07f329cd74a7a76c05d7dec6ce796a8c", "digest": "630841d36514c55c64864274186ff52e5bfa2037e6595d7bc1424637b37f68e7", "submission_hash": "c5ff27d2b8a7c38512a3a9a51eb51a6513334a449f923700a2ad64b8ae8272c6"],
        ["role": "1", "policy": "2", "request_hash": "7bffd24f044a0d62937d40460395e831b9727fa616296d28f11122f61d8cc830", "digest": "ff1ec79c0992df5aaf5cee15b3a9eaaf78846a68e2ee3c73bb55f60a335695cb", "submission_hash": "ca2a338a44237aae86214ed782cc5e177fac82a7f89876fd0ec296fb07f71dcc"],
        ["role": "2", "policy": "1", "request_hash": "a22770697e7487a6422418fc91d2483fe6959f60b6a4d37fc2f65b3583c87db2", "digest": "f2b831b48815d699990607b21539e8ed34550ec530d4743edb620da61fd0e1ae", "submission_hash": "a3ffad86b32d1db2b30ed068f1b8c4b283ab9783ed6685510531daeef181bcbc"],
        ["role": "2", "policy": "2", "request_hash": "9277bdb7d71f9b72b55f09ac32c982c0d9c089d242a8fb9d4439b12bd363ad8a", "digest": "368b1dc85f92b8968b825a7e21da3a332e54aeaa5ad1141efbab13406445519b", "submission_hash": "c204539096696abb9a34c3505434cd38a9e80d2246e92d609a92c9868e306d30"]
    ]
    private let preparations: [[String: String]] = [
        ["module_amount": "1", "vault_amount": "1", "request_hash": "992ccaa3160ca76650fa48916cca1de122dac22f6dec2bebdd5c9b8cef5944ff", "submission_hash": "f1c71045b99ae68b41eed8137328ea6b8381c522731b6b175d0fa278774f5d38"],
        ["module_amount": "10000000000", "vault_amount": "20000000000", "request_hash": "0e84ef7c41cf1b85350867fb17a12540c3a027beacbdd08ec5f9f9cd0c47b4c8", "submission_hash": "9769899470ce42de9da8b53a5f39a418c2d7d8c7e3199cde90fe6b50cbf15be4"],
        ["module_amount": "18446744073709551616", "vault_amount": "1329227995784915872903807060280344575", "request_hash": "00f6d7d00a6f84e894ce8bd0a2f25df244b29ab28bbfbfdd32f970e170c80971", "submission_hash": "67a7a7f77fef9f95b4c2394a2a67a1246b8a37c61923d519f94d9b0398c5be44"]
    ]
    func testAllIndependentPopRolesPoliciesAndSubmissions() throws {
        for v in pops {
            let role: TOSQuantumRole = v["role"] == "1" ? .primary : .rescue
            let r = try TOSQuantumPop(binding: binding(), role: role, policy: v["policy"] == "1" ? .ready : .required,
                primaryKeyChainHash: hash(111), rescueKey: hash(222), challenge: hash(99), provenTime: 1780000000)
            XCTAssertEqual(r.request.hash(), Data(hex: try XCTUnwrap(v["request_hash"])))
            XCTAssertEqual(r.digest, Data(hex: try XCTUnwrap(v["digest"])))
            XCTAssertEqual(try r.submission(signature: Data(repeating: 0xa5, count: role.signatureSize)).hash(), Data(hex: try XCTUnwrap(v["submission_hash"])))
        }
    }
    func testAllIndependentPreparationAmountsAndSubmissions() throws {
        for v in preparations {
            let a = try XCTUnwrap(BigUInt(try XCTUnwrap(v["module_amount"]))), b = try XCTUnwrap(BigUInt(try XCTUnwrap(v["vault_amount"])))
            let r = try TOSQuantumPreparation(binding: binding(), moduleAmount: a, vaultAmount: b, moduleInit: byte(1), metadata: byte(2), vaultInit: byte(3), provenTime: 1780000000)
            XCTAssertEqual(r.digest, Data(hex: try XCTUnwrap(v["request_hash"])))
            XCTAssertEqual(r.deploymentValue, a + b)
            XCTAssertEqual(try r.submission(signature: Data(repeating: 0xa5, count: 7856)).hash(), Data(hex: try XCTUnwrap(v["submission_hash"])))
        }
    }
    func testMalformedChallengeAmountDeadlineAndSignatureRefused() throws {
        for c in [Data(count: 32), Data(repeating: 1, count: 31), Data(repeating: 1, count: 33)] {
            XCTAssertThrowsError(try TOSQuantumPop(binding: binding(), role: .primary, policy: .ready, primaryKeyChainHash: hash(111), rescueKey: hash(222), challenge: c, provenTime: 1780000000))
        }
        for a in [BigUInt(0), BigUInt(1) << 120] {
            XCTAssertThrowsError(try TOSQuantumPreparation(binding: binding(), moduleAmount: a, vaultAmount: 1, moduleInit: byte(1), metadata: byte(2), vaultInit: byte(3), provenTime: 1780000000))
        }
        for deadline in [UInt32(1780000000), UInt32(1780003601)] {
            XCTAssertThrowsError(try TOSQuantumPop(binding: binding(deadline), role: .rescue, policy: .ready, primaryKeyChainHash: hash(111), rescueKey: hash(222), challenge: hash(99), provenTime: 1780000000))
        }
        let r = try TOSQuantumPreparation(binding: binding(), moduleAmount: 1, vaultAmount: 1, moduleInit: byte(1), metadata: byte(2), vaultInit: byte(3), provenTime: 1780000000)
        for count in [64,2420,7855,7857] { XCTAssertThrowsError(try r.submission(signature: Data(count: count))) }
    }
}
