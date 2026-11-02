import XCTest
import BigInt
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSQuantumSelfPayAccountTests: XCTestCase {
    private func wallet() throws -> TOSQuantumSelfPayWallet {
        try TOSQuantumSelfPayWallet(authority: TOSQuantumSelfPayAuthority(globalID: 1,
            namespace: Data(repeating: 0x42, count: 32), primaryKey: Data(count: 1312), rescueKey: Data(count: 32)))
    }
    func testFreshMasterchainDoesNotRefreshStaleShardState() throws {
        try TOSQuantumSelfPayAccount.validateTime(master: 1000, shard: 700, now: 1000, maximumAge: 300)
        for (master, shard, now): (UInt32, UInt32, Int64) in [(1000, 699, 1000), (1000, 1001, 1000), (1061, 1061, 1000)] {
            XCTAssertThrowsError(try TOSQuantumSelfPayAccount.validateTime(master: master, shard: shard, now: now, maximumAge: 300))
        }
    }
    private func account(_ wallet: TOSQuantumSelfPayWallet, frozen: Bool = false, tail: Bool = false,
                         state: TOSQuantumSelfPayState? = nil, code: Cell? = nil) throws -> Data {
        let b = try Builder().store(bit: true).store(wallet.address).store(uint: 0, bits: 6)
            .store(uint: frozen ? 0 : 1, bits: 3)
        if !frozen { try b.store(data: Data(count: 32)) }
        try b.store(uint: 100, bits: 32)
            .store(bit: true).store(uint: 1, bits: 4).store(uint: 128, bits: 8).store(uint: 0, bits: 64)
            .store(uint: 15, bits: 4).store(data: Data(repeating: 255, count: 15)).store(bit: false)
        if let state {
            try b.store(bit: true).store(uint: 0, bits: 2).store(bit: true).store(ref: code ?? wallet.code)
                .store(bit: true).store(ref: state.cell).store(bit: false)
        } else {
            try b.store(bit: false).store(bit: frozen)
            if frozen { try b.store(data: wallet.stateInit.hash()) }
        }
        if tail { try b.store(bit: false) }
        return try b.endCell().toBoc()
    }

    func testFrozenAndUninitializedAreDistinctAndPreserveUnsignedAmounts() throws {
        let w = try wallet()
        for frozen in [false, true] {
            let s = try TOSQuantumSelfPayAccount.decode(account(w, frozen: frozen), wallet: w)
            XCTAssertEqual(s.balance, (BigUInt(1) << 120) - 1)
            XCTAssertEqual(s.storageDebt, 128); XCTAssertEqual(s.lastPaid, 100)
            switch s.status {
            case .frozen(let hash): XCTAssertTrue(frozen); XCTAssertEqual(hash, w.stateInit.hash())
            case .uninitialized: XCTAssertFalse(frozen)
            default: XCTFail("Unexpected account status")
            }
            XCTAssertThrowsError(try TOSQuantumSelfPayAccount.decode(account(w, frozen: frozen, tail: true), wallet: w))
        }
    }

    func testActiveStateUsesCurrentAuthorityButRetainsBirthAddressAndCode() throws {
        let w = try wallet()
        let successor = try TOSQuantumSelfPayAuthority(globalID: 1, namespace: w.initialAuthority.namespace,
            primaryKey: Data(repeating: 1, count: 1312), rescueKey: Data(repeating: 2, count: 32), policy: .required)
        let state = try TOSQuantumSelfPayState(authority: successor, seqno: 4, epoch: 1)
        let observation = try TOSQuantumSelfPayAccount.decode(account(w, state: state), wallet: w)
        guard case .active(let active) = observation.status else { return XCTFail("Expected active") }
        XCTAssertEqual(active.authority.hash, successor.hash); XCTAssertEqual(active.seqno, 4)
        XCTAssertThrowsError(try TOSQuantumSelfPayAccount.decode(account(w, state: state,
            code: Builder().endCell()), wallet: w))
        XCTAssertThrowsError(try TOSQuantumSelfPayAccount.decode(account(w,
            state: TOSQuantumSelfPayState(authority: successor, walletID: 1)), wallet: w))
    }

    /// New self-pay chain capture, replayed through the native verifier at its recorded time.
    func testNativeProofsBindAllThreeBirthIdentitiesAndRejectTransplants() throws {
        let base = try XCTUnwrap(Bundle.module.url(forResource: "quantum-self-pay-live", withExtension: nil))
        func read(_ path: String) throws -> Data { try Data(contentsOf: base.appendingPathComponent(path)) }
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: read("manifest.json")) as? [String: Any])
        let now = try XCTUnwrap(manifest["controlled_now"] as? NSNumber).int64Value
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: read("public-self-pay-accounts.json")) as? [String: Any])
        let records = try XCTUnwrap(fixture["accounts"] as? [String: [String: Any]])
        func identity(_ role: String) throws -> TOSQuantumSelfPayIdentity {
            try TOSQuantumSelfPayIdentity(boc: XCTUnwrap(Data(base64Encoded: XCTUnwrap(records[role]?["identity_boc"] as? String))))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        func prove(_ role: String, corrupt: Bool = false) throws -> TOSQuantumProofBridge.BoundRead {
            let session = try TOSQuantumProofSession(walletID: UUID(), locallyProvisionedAnchor: read("anchor.json"), baseDirectory: directory)
            let names = role == "policy" ? ["masterchain-info.tl", "chain-0000.tl", "config.tl"] : ["chain-0000.tl", "account.tl"]
            var replies = try names.map { try read(role + "/material/" + $0) }
            // Corrupt the returned masterchain root, not ignored TL padding.
            if corrupt { replies[replies.count - 1][20] ^= 1 }
            var calls = 0
            let result = try session.enrollBound(request: read(role + "/request.json"), now: now) { _, capacity in
                guard calls < replies.count, replies[calls].count <= capacity else { throw TOSPQError.invalidInput }
                defer { calls += 1 }; return replies[calls]
            }
            XCTAssertEqual(calls, names.count)
            return result
        }
        let policy = try prove("policy")
        let network = try TOSQuantumSelfPayNetwork(proof: policy, expectedGlobalID: 1, now: now, maximumAge: 300)
        for role in ["active", "prefunded", "absent"] {
            let birth = try identity(role), proof = try prove(role)
            try network.requireSameCheckpoint(proof, now: now)
            XCTAssertEqual(try network.makeIdentity(primaryKey: birth.wallet.initialAuthority.primaryKey,
                rescueKey: birth.wallet.initialAuthority.rescueKey, walletID: birth.wallet.walletID, now: now), birth)
            let account = try TOSQuantumSelfPayAccount(identity: birth, proof: proof, now: now, maximumAge: 300)
            let s = try account.snapshot(now: now)
            switch (role, s.status) {
            case ("active", .active(let state)):
                XCTAssertEqual(state.cell.hash(), birth.wallet.initialData.hash()); XCTAssertEqual(s.balance, 1_000_000_000_000_000)
            case ("prefunded", .uninitialized): XCTAssertEqual(s.balance, 10_000_000_000)
            case ("absent", .absent): XCTAssertEqual(s.balance, 0)
            default: XCTFail("Wrong proven status for \(role)")
            }
            XCTAssertThrowsError(try account.snapshot(now: now + 301))
            XCTAssertThrowsError(try TOSQuantumSelfPayAccount(identity: birth, proof: proof, now: now + 301, maximumAge: 300))
            let other = try identity(role == "active" ? "prefunded" : "active")
            XCTAssertThrowsError(try TOSQuantumSelfPayAccount(identity: other, proof: proof, now: now, maximumAge: 300))
        }
        XCTAssertThrowsError(try prove("active", corrupt: true))
    }
}
