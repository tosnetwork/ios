import XCTest
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSQuantumSelfPayTests: XCTestCase {
    private func vector() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tos-quantum-self-pay", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func bytes(_ v: [String: Any], _ key: String) throws -> Data {
        Data(hex: try XCTUnwrap(v[key] as? String))
    }
    private func authority(_ v: [String: Any], policy: TOSQuantumPolicy = .ready) throws -> TOSQuantumSelfPayAuthority {
        try TOSQuantumSelfPayAuthority(globalID: 42, namespace: bytes(v, "namespace"),
            primaryKey: bytes(v, "primary_key"), rescueKey: bytes(v, "rescue_key"), policy: policy)
    }
    private func policy(_ v: [String: Any], retired: UInt16 = 0) throws -> Cell {
        try Builder().store(uint: 0xa1, bits: 8).store(data: bytes(v, "namespace")).store(uint: 0, bits: 64)
            .store(uint: retired, bits: 16).store(bit: false)
            .store(data: Data(hex: "5e4380aedc95f8cb72de55f7506de0269b47c03ad1d1ed0e5184c332544262c0")).endCell()
    }

    func testReadyMigrationAndPrimaryRequirePolicyWhileRequiredRescueDoesNot() throws {
        let v = try vector(), a = try authority(v), wallet = try TOSQuantumSelfPayWallet(authority: a)
        let state = try TOSQuantumSelfPayState(authority: a)
        func migrate(_ successor: TOSQuantumSelfPayAuthority, _ cp48: Cell? = nil) throws -> TOSQuantumSelfPayRequest {
            try TOSQuantumSelfPayRequest(wallet: wallet.address, state: state, role: .rescue,
                validUntil: 1780000600, action: .migrate(successor), provenTime: 1780000000, primaryPolicy: cp48)
        }
        XCTAssertThrowsError(try migrate(a))
        XCTAssertThrowsError(try migrate(a, policy(v, retired: 2)))
        XCTAssertNoThrow(try migrate(a, policy(v)))
        XCTAssertNoThrow(try migrate(authority(v, policy: .required)))
        XCTAssertNoThrow(try migrate(authority(v, policy: .required), policy(v, retired: 2)))
        for cp48 in [nil, try policy(v, retired: 2)] {
            XCTAssertThrowsError(try TOSQuantumSelfPayRequest(wallet: wallet.address, state: state, role: .primary,
                validUntil: 1780000600, action: .execute(Builder().endCell()), provenTime: 1780000000, primaryPolicy: cp48))
        }
        XCTAssertThrowsError(try TOSQuantumSelfPayRequest(wallet: wallet.address,
            state: TOSQuantumSelfPayState(authority: a, retired: 2), role: .rescue, validUntil: 1780000600,
            action: .migrate(a), provenTime: 1780000000, primaryPolicy: policy(v)))
    }

    func testBirthIdentitySurvivesRotationAndRejectsSubstitutedRestoreData() throws {
        let v = try vector(), a = try authority(v), wallet = try TOSQuantumSelfPayWallet(authority: a)
        let identity = try TOSQuantumSelfPayIdentity(wallet: wallet)
        XCTAssertEqual(identity.cell.hash(), try bytes(v, "identity_hash"))
        let golden = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(v["identity_boc"] as? String)))
        XCTAssertEqual(identity, try TOSQuantumSelfPayIdentity(boc: golden))
        let restored = try JSONDecoder().decode(TOSQuantumSelfPayIdentity.self, from: JSONEncoder().encode(identity))
        XCTAssertEqual(identity, restored)
        XCTAssertNoThrow(try restored.requireNetwork(globalID: 42, namespace: a.namespace))
        XCTAssertThrowsError(try restored.requireNetwork(globalID: 43, namespace: a.namespace))
        XCTAssertThrowsError(try restored.requireNetwork(globalID: 42, namespace: Data(count: 32)))
        var newKey = a.primaryKey; newKey[0] ^= 1
        let successor = try TOSQuantumSelfPayAuthority(globalID: 42, namespace: a.namespace, primaryKey: newKey, rescueKey: a.rescueKey)
        let rotated = try TOSQuantumSelfPayState(authority: successor, epoch: 1)
        XCTAssertEqual(restored.address, wallet.address)
        XCTAssertEqual(try restored.wallet.readState(account: restored.address, code: wallet.code, data: rotated.cell).authority.hash, successor.hash)
        XCTAssertNotEqual(wallet.address, try TOSQuantumSelfPayWallet(authority: successor).address)
        func encoded(_ initial: Cell, address: Address? = nil) throws -> Cell {
            try Builder().store(uint: 0x51534931, bits: 32).store(data: address?.hash ?? initial.hash()).store(ref: initial).endCell()
        }
        XCTAssertThrowsError(try TOSQuantumSelfPayIdentity(cell: encoded(TOSQuantumSelfPayWallet.stateInit(code: wallet.code, data: rotated.cell))))
        XCTAssertThrowsError(try TOSQuantumSelfPayIdentity(cell: encoded(TOSQuantumSelfPayWallet.stateInit(code: Builder().endCell(), data: wallet.initialData))))
        XCTAssertThrowsError(try TOSQuantumSelfPayIdentity(cell: encoded(wallet.stateInit, address: Address(workchain: 0, hash: Data(count: 32)))))
        XCTAssertThrowsError(try TOSQuantumSelfPayIdentity(boc: Data(count: TOSQuantumSelfPayIdentity.maximumBOCBytes + 1)))
        for malformed in try TOSRPCBOCTestFixtures.malformedBase64() {
            XCTAssertThrowsError(try TOSQuantumSelfPayIdentity(boc: XCTUnwrap(Data(base64Encoded: malformed))))
        }
    }

    func testVmExecutedAddressStateAllRequestsAndNativeSignatureDomains() throws {
        let v = try vector(), a = try authority(v)
        let wallet = try TOSQuantumSelfPayWallet(authority: a)
        XCTAssertEqual(wallet.code.hash(), try bytes(v, "wallet_code_hash"))
        XCTAssertEqual(a.hash, try bytes(v, "authority_hash"))
        XCTAssertEqual(wallet.initialData.hash(), try bytes(v, "initial_state_hash"))
        XCTAssertEqual(wallet.address, try Address.parse(XCTUnwrap(v["wallet_address"] as? String)))
        let state = try wallet.readState(account: wallet.address, code: wallet.code, data: wallet.initialData)
        XCTAssertEqual(state.epoch, 0)
        XCTAssertEqual(state.cell.hash(), wallet.initialData.hash())
        for row in try XCTUnwrap(v["cases"] as? [[String: Any]]) {
            let role: TOSQuantumRole = (row["role"] as? Int) == 1 ? .primary : .rescue
            let action: TOSQuantumSelfPayAction
            switch row["kind"] as? Int {
            case 0: action = .execute(try Builder().endCell())
            case 1: action = .configureRequired
            case 3: action = .lockPrimary
            default: action = .migrate(try authority(v, policy: .required))
            }
            let r = try TOSQuantumSelfPayRequest(wallet: wallet.address, state: state, role: role,
                validUntil: 1780000600, action: action, provenTime: 1780000000, primaryPolicy: policy(v))
            XCTAssertEqual(r.digest, try bytes(row, "request_hash"))
            let signature = try bytes(row, "signature"), body = try r.submission(signature: signature)
            XCTAssertEqual(body.hash(), try bytes(row, "submission_hash"))
            XCTAssertEqual(try wallet.external(body: body, deploy: false).hash(), try bytes(row, "external_hash"))
            let publicKey = role == .primary ? a.primaryKey : a.rescueKey
            XCTAssertTrue(TOSQuantumSigner.verify(role: role, purpose: .selfPay, publicKey: publicKey, digest: r.digest, signature: signature))
            for other in [TOSQuantumPurpose.auth, .pop, .selfPayPop] {
                XCTAssertFalse(TOSQuantumSigner.verify(role: role, purpose: other, publicKey: publicKey, digest: r.digest, signature: signature))
            }
        }
    }

    func testProofRequiresOriginalUnverifiedAddressAndBothNewSigningDomains() throws {
        let v = try vector(), a = try authority(v), wallet = try TOSQuantumSelfPayWallet(authority: a)
        let row = try XCTUnwrap(v["probe"] as? [String: Any])
        let probe = try TOSQuantumSelfPayProbe(wallet: wallet.address, authority: a, challenge: bytes(row, "challenge"),
            validUntil: 1780000600, provenTime: 1780000000)
        XCTAssertEqual(probe.address, try Address.parse(XCTUnwrap(row["address"] as? String)))
        XCTAssertEqual(try probe.digest, try bytes(row, "digest"))
        XCTAssertEqual(probe.immutable.hash(), try bytes(row, "immutable_hash"))
        XCTAssertEqual(probe.initialData.hash(), try bytes(row, "initial_state_hash"))
        let verified = try Builder().store(uint: 1, bits: 8).store(bit: true).store(ref: probe.immutable).endCell()
        XCTAssertNoThrow(try probe.requireVerified(account: probe.address, installedCode: probe.code, installedData: verified))
        XCTAssertThrowsError(try probe.requireVerified(account: probe.address, installedCode: probe.code, installedData: probe.initialData))
        let forged = Address(workchain: 0, hash: try TOSQuantumSelfPayWallet.stateInit(code: probe.code, data: verified).hash())
        XCTAssertNotEqual(forged, probe.address)
        XCTAssertThrowsError(try probe.requireVerified(account: forged, installedCode: probe.code, installedData: verified))
        for role in [TOSQuantumRole.primary, .rescue] {
            let seed = try bytes(v, role == .primary ? "primary_seed" : "rescue_seed")
            let key = role == .primary ? a.primaryKey : a.rescueKey
            let signature = try TOSQuantumSigner.sign(role: role, purpose: .selfPayPop, seed: seed, expectedPublicKey: key, digest: probe.digest)
            XCTAssertTrue(TOSQuantumSigner.verify(role: role, purpose: .selfPayPop, publicKey: key, digest: try probe.digest, signature: signature))
            XCTAssertFalse(TOSQuantumSigner.verify(role: role, purpose: .selfPay, publicKey: key, digest: try probe.digest, signature: signature))
        }
    }

    func testSaturatedExecutionCountersRetainRescueControlsAndStrictStateParsing() throws {
        let v = try vector(), a = try authority(v), wallet = try TOSQuantumSelfPayWallet(authority: a)
        func request(_ state: TOSQuantumSelfPayState, _ action: TOSQuantumSelfPayAction, role: TOSQuantumRole = .rescue) throws -> TOSQuantumSelfPayRequest {
            try TOSQuantumSelfPayRequest(wallet: wallet.address, state: state, role: role,
                validUntil: 1780000600, action: action, provenTime: 1780000000)
        }
        let saturated = try TOSQuantumSelfPayState(authority: a, seqno: .max, rescueNonce: .max)
        XCTAssertNoThrow(try request(saturated, .lockPrimary))
        XCTAssertNoThrow(try request(saturated, .migrate(authority(v, policy: .required))))
        XCTAssertThrowsError(try request(saturated, .execute(Builder().endCell())))
        XCTAssertThrowsError(try request(TOSQuantumSelfPayState(authority: a, epoch: .max), .lockPrimary))
        XCTAssertThrowsError(try request(TOSQuantumSelfPayState(authority: a, retired: 2), .execute(Builder().endCell()), role: .primary))
        XCTAssertThrowsError(try request(TOSQuantumSelfPayState(authority: a), .lockPrimary, role: .primary))
        let trailing = try Builder().store(slice: wallet.initialData.beginParse()).store(bit: false).endCell()
        XCTAssertThrowsError(try TOSQuantumSelfPayState.parse(trailing))
        XCTAssertThrowsError(try wallet.readState(account: Address(workchain: 0, hash: Data(count: 32)), code: wallet.code, data: wallet.initialData))
    }
}
