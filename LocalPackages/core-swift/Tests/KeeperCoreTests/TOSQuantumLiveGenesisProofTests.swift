import XCTest
import Foundation
import BigInt
import TonSwift
import CoreComponents
@testable import KeeperCore

/// Real captured proofs at controlled fixture time; not current operation or signing acceptance.
final class TOSQuantumLiveGenesisProofTests: XCTestCase {
    private func chain(_ root: Cell) throws -> Data {
        var result = Data(), current = root
        while true {
            let s = try current.beginParse()
            guard s.remainingBits % 8 == 0, s.remainingRefs <= 1 else { throw TOSPQError.invalidInput }
            result.append(try s.loadBytes(s.remainingBits / 8))
            if s.remainingRefs == 0 { return result }
            current = try s.loadRef()
        }
    }
    func testNativeProofsBindActualGenesisTuple() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = try XCTUnwrap(Bundle.module.url(forResource: "quantum-live-genesis", withExtension: nil))
        func read(_ name: String) throws -> Data { try Data(contentsOf: base.appendingPathComponent(name)) }
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: read("public-genesis-accounts.json")) as? [String: Any])
        let input = try XCTUnwrap(fixture["input"] as? [String: Any]).compactMapValues { $0 as? String }
        let output = try XCTUnwrap(fixture["output"] as? [String: String])
        func cell(_ text: String) throws -> Cell { try XCTUnwrap(Cell.fromBoc(src: Data(hex: text)).first) }
        let codes = try TOSQuantumCodes(wallet: cell(input["wallet_code"]!), module: cell(input["module_code"]!), vault: cell(input["vault_code"]!))
        let module = try cell(output["module_data"]!).beginParse()
        XCTAssertEqual(try module.loadUint(bits: 8), 1)
        let global = Int32(try module.loadInt(bits: 32)), network = try module.loadBytes(32)
        XCTAssertEqual(try module.loadUint(bits: 8), 1)
        let primary = try chain(module.loadRef()), rescue = try module.loadBytes(32)
        let policy = UInt8(try module.loadUint(bits: 8))
        let wd = try cell(output["wallet_data"]!), wallet = try wd.beginParse(); try wallet.skip(33)
        let walletID = UInt32(try wallet.loadUint(bits: 32))
        let auth = try wallet.loadRef().beginParse(); _ = try auth.loadRef()
        let metadata = try auth.loadRef().beginParse(); try metadata.skip(16)
        let tree = try metadata.loadBytes(32), epoch0 = UInt32(try metadata.loadUint(bits: 32)), fee = try chain(metadata.loadRef())
        let pins = TOSQuantumCodePins(wallet: codes.wallet.hash(), module: codes.module.hash(), vault: codes.vault.hash())
        let birth = try TOSQuantumGenesis(codes: codes, pins: pins, globalId: global, network: network, walletId: walletID,
            primaryKey: primary, rescueKey: rescue, policy: XCTUnwrap(TOSQuantumPolicy(rawValue: policy)), feeTreeId: tree, feePublicKey: fee, epoch0: epoch0)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: read("manifest.json")) as? [String: Any])
        let now = try XCTUnwrap(manifest["controlled_now"] as? NSNumber).int64Value
        func prove(_ role: String) throws -> TOSQuantumProofBridge.BoundRead {
            let session = try TOSQuantumProofSession(walletID: UUID(), locallyProvisionedAnchor: read("anchor.json"), baseDirectory: directory)
            let names = role == "policy" ? ["masterchain-info.tl", "chain-0000.tl", "config.tl", "account.tl"] : ["chain-0000.tl", "account.tl"]
            let replies = try names.map { try read(role + "/material/" + $0) }
            var calls = 0
            let result = try session.enrollBound(request: read(role + "/request.json"), now: now) { _, capacity in
                guard calls < replies.count, replies[calls].count <= capacity else { throw TOSPQError.invalidInput }
                defer { calls += 1 }; return replies[calls]
            }
            XCTAssertEqual(calls, names.count)
            return result
        }
        let walletProof = try prove("wallet"), moduleProof = try prove("module"), vaultProof = try prove("vault")
        let installed = try TOSQuantumInstalledWallet.bindInitial(birth: birth, wallet: walletProof, module: moduleProof, vault: vaultProof, now: now, maximumAge: 300)
        XCTAssertEqual(installed.state.epoch, 1); XCTAssertEqual(installed.nextFeeLeaf, 0)
        XCTAssertEqual(installed.walletAccount.balance, BigUInt(1_000_000_000_000_000))
        try installed.requireFeeProof(now: now, maximumAge: 300)
        try installed.requireRescueCustody(rescue, now: now, maximumAge: 300)
        var badRescue = rescue; badRescue[0] ^= 1
        XCTAssertThrowsError(try installed.requireRescueCustody(badRescue, now: now, maximumAge: 300), "Wrong current SLH key accepted")
        XCTAssertThrowsError(try installed.requireRescueCustody(rescue, now: now + 301, maximumAge: 300), "Expired SLH proof accepted")
        let policyProof = try prove("policy")
        try installed.requirePrimaryExecution(policyProof: policyProof, now: now, maximumAge: 300)
        try installed.requirePrimaryCustody(primary, policyProof: policyProof, now: now, maximumAge: 300)
        let actions = try Builder().endCell()
        let request = try installed.primaryExecuteRequest(policyProof: policyProof, actions: actions, validUntil: UInt32(now + 60), now: now, maximumAge: 300)
        XCTAssertEqual(request.role, .primary)
        var badKey = primary; badKey[0] ^= 1
        XCTAssertThrowsError(try installed.requirePrimaryCustody(badKey, policyProof: policyProof, now: now, maximumAge: 300), "Wrong current PRIMARY key accepted")
        XCTAssertThrowsError(try installed.primaryExecuteRequest(policyProof: policyProof, actions: actions, validUntil: UInt32(now), now: now, maximumAge: 300), "Expired PRIMARY request accepted")

        XCTAssertThrowsError(try walletProof.requireLive(now: now + 301, maximumAge: 300), "Expired proof passed freshness gate")
    }
}
