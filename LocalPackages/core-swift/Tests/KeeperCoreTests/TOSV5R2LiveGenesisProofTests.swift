import XCTest
import Foundation
import BigInt
import TonSwift
import CoreComponents
@testable import KeeperCore

/// Real captured proofs at controlled fixture time; not current operation or signing acceptance.
final class TOSV5R2LiveGenesisProofTests: XCTestCase {
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
        let base = try XCTUnwrap(Bundle.module.url(forResource: "v5r2-live-genesis", withExtension: nil))
        func read(_ name: String) throws -> Data { try Data(contentsOf: base.appendingPathComponent(name)) }
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: read("public-genesis-accounts.json")) as? [String: Any])
        let input = try XCTUnwrap(fixture["input"] as? [String: Any]).compactMapValues { $0 as? String }
        let output = try XCTUnwrap(fixture["output"] as? [String: String])
        func cell(_ text: String) throws -> Cell { try XCTUnwrap(Cell.fromBoc(src: Data(hex: text)).first) }
        let codes = try TOSV5R2Codes(wallet: cell(input["wallet_code"]!), module: cell(input["module_code"]!), vault: cell(input["vault_code"]!))
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
        let pins = TOSV5R2CodePins(wallet: codes.wallet.hash(), module: codes.module.hash(), vault: codes.vault.hash())
        let birth = try TOSV5R2Genesis(codes: codes, pins: pins, globalId: global, network: network, walletId: walletID,
            primaryKey: primary, rescueKey: rescue, policy: XCTUnwrap(TOSV5R2Policy(rawValue: policy)), feeTreeId: tree, feePublicKey: fee, epoch0: epoch0)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: read("manifest.json")) as? [String: Any])
        let now = try XCTUnwrap(manifest["controlled_now"] as? NSNumber).int64Value
        func prove(_ role: String) throws -> TOSV5R2ProofBridge.BoundRead {
            let session = try TOSV5R2ProofSession(walletID: UUID(), locallyProvisionedAnchor: read("anchor.json"), baseDirectory: directory)
            let replies = try [read(role + "/material/chain-0000.tl"), read(role + "/material/account.tl")]
            var calls = 0
            let result = try session.enrollBound(request: read(role + "/request.json"), now: now) { _, capacity in
                guard calls < replies.count, replies[calls].count <= capacity else { throw TOSPQError.invalidInput }
                defer { calls += 1 }; return replies[calls]
            }
            XCTAssertEqual(calls, 2)
            return result
        }
        let walletProof = try prove("wallet"), moduleProof = try prove("module"), vaultProof = try prove("vault")
        let installed = try TOSV5R2InstalledWallet.bindInitial(birth: birth, wallet: walletProof, module: moduleProof, vault: vaultProof, now: now, maximumAge: 300)
        XCTAssertEqual(installed.state.epoch, 1); XCTAssertEqual(installed.nextFeeLeaf, 0)
        XCTAssertEqual(installed.walletAccount.balance, BigUInt(1_000_000_000_000_000))
        try installed.requireFeeProof(now: now, maximumAge: 300)
        XCTAssertThrowsError(try walletProof.requireLive(now: now + 301, maximumAge: 300), "Expired proof passed freshness gate")
    }
}
