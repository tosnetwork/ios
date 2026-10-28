import XCTest
import BigInt
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSQuantumPaymentCoordinatorTests: XCTestCase {
    private final class Fixture {
        let base: URL, outbox: TOSQuantumOutbox, assets: URL, id = UUID()
        let profile: TOSQuantumNetworkProfile, identity: TOSQuantumSelfPayIdentity
        var clock: Int64
        var signs = 0, sends = [Data]()
        var corruptedProofs = 0
        var onSign: (() -> Void)?, onBroadcast: (() throws -> Void)?
        var onNowRead: (() -> Void)?
        init() throws {
            let resources = try XCTUnwrap(Bundle.module.url(forResource: "quantum-payment", withExtension: nil))
            assets = resources
            func data(_ name: String) throws -> Data { try Data(contentsOf: resources.appendingPathComponent(name)) }
            clock = try XCTUnwrap(Int64(String(decoding: data("clock.txt"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            let accounts = try XCTUnwrap(Bundle.module.url(forResource: "quantum-self-pay-live", withExtension: nil))
            let registry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: accounts.appendingPathComponent("public-self-pay-accounts.json"))) as? [String: Any])
            let records = try XCTUnwrap(registry["accounts"] as? [String: [String: Any]])
            identity = try TOSQuantumSelfPayIdentity(boc: XCTUnwrap(Data(base64Encoded: XCTUnwrap(records["active"]?["identity_boc"] as? String))))
            let anchor = try XCTUnwrap(JSONSerialization.jsonObject(with: data("anchor.json")) as? [String: Any])
            profile = try TOSQuantumNetworkProfile(globalID: 1, rootHash: XCTUnwrap(anchor["root_hash"] as? String),
                fileHash: XCTUnwrap(anchor["file_hash"] as? String))
            base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            outbox = try TOSQuantumOutbox(baseDirectory: base.appendingPathComponent("outbox"))
            try TOSQuantumCreationRecord(id: id, profile: profile, identity: identity).save(baseDirectory: base)
            let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: profile.anchor(), baseDirectory: base)
            let request = try JSONSerialization.data(withJSONObject: ["mode": "live", "max_age_seconds": 300, "config_params": [8, 19, 48]])
            let material = try [(1, "masterchain-info.tl"), (2, "chain-0000.tl"), (4, "exec-config.tl")].map { kind, name in
                TOSQuantumProofBridge.Material(kind: UInt32(kind), bytes: try data("material/" + name))
            }
            _ = try session.enroll(request: request, now: clock, material: material)
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func query(_ query: Data, capacity: Int) throws -> Data {
            let name: String
            switch query.count {
            case 4: name = "masterchain-info.tl"
            case 168: name = "chain-0000.tl"
            case 120: name = "account.tl"
            case 88, 96, 104: name = "exec-config.tl"
            default: throw TOSPQError.invalidInput
            }
            let bytes = try Data(contentsOf: assets.appendingPathComponent("material/" + name))
            XCTAssertLessThanOrEqual(bytes.count, capacity)
            return bytes
        }
        func payment(amount: BigUInt = 10_000_000_000, comment: String? = nil) throws -> TOSQuantumPreparedPayment {
            let reader = TOSQuantumAccountReader(baseDirectory: base, transport: { self.query }, now: { self.clock })
            let observation = try reader.observeEnrolled(id: id, identity: identity, profile: profile, configIndices: [8, 19, 48])
            let recipient = try Address.parse("0:8cd34918c9b179b3f22da35bf741c9713f2b19642871e03f777280db2594bbd0")
            let intent = try TOSQuantumPaymentIntent(recipient: recipient, amount: amount, bounce: false, comment: comment)
            return try TOSQuantumPreparedPayment(observation: observation, intent: intent, now: clock, ttl: 120)
        }
        func wallet() -> Wallet {
            Wallet(id: id.uuidString, identity: WalletIdentity(network: .mainnet, kind: .Quantum(identity), networkGlobalId: profile.globalID),
                metaData: WalletMetaData(label: "Public fixture", tintColor: .defaultColor, icon: .icon(.wallet)),
                setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
        }
        func outcomes(corruptProof: Bool = false, beforeProof: ((TOSQuantumHistoryReader.StopFlag) -> Void)? = nil) -> TOSQuantumPaymentOutcomeReader {
            TOSQuantumPaymentOutcomeReader(outbox: outbox, baseDirectory: base, accounts: { flag in
                TOSQuantumAccountReader(baseDirectory: self.base, transport: {
                    return { query, capacity in
                        beforeProof?(flag)
                        guard !flag.stopped() else { throw TOSPQError.invalidInput }
                        var bytes = try self.query(query, capacity: capacity)
                        if corruptProof && query.count == 120 { bytes[bytes.count / 2] ^= 1; self.corruptedProofs += 1 }
                        return bytes
                    }
                }, now: { self.clock })
            }, query: { _ in
                return { _, _, _ in XCTFail("Proven genesis head must not query transactions"); throw TOSPQError.invalidInput }
            }, now: { self.clock })
        }
        func expiries(corruptProof: Bool = false, beforeProof: ((TOSQuantumHistoryReader.StopFlag) -> Void)? = nil) -> TOSQuantumAuthorizationExpiryReader {
            TOSQuantumAuthorizationExpiryReader(outbox: outbox, baseDirectory: base, accounts: { flag in
                TOSQuantumAccountReader(baseDirectory: self.base, transport: {
                    return { query, capacity in
                        beforeProof?(flag)
                        guard !flag.stopped() else { throw TOSPQError.invalidInput }
                        var bytes = try self.query(query, capacity: capacity)
                        if corruptProof && query.count == 120 { bytes[bytes.count / 2] ^= 1; self.corruptedProofs += 1 }
                        return bytes
                    }
                }, now: { self.clock })
            }, now: { self.clock })
        }
        func expiryEntry(delta: Int64 = -1, phase: TOSQuantumOutbox.Phase = .reserved) throws -> TOSQuantumOutbox.Entry {
            let payment = try payment()
            let observation = try TOSQuantumAccountReader(baseDirectory: base, transport: { self.query }, now: { self.clock })
                .observeEnrolled(id: id, identity: identity, profile: profile, configIndices: [8, 19, 48])
            let shard = try observation.proof.provenAccountTime(expectedAddress: identity.address.toRaw())
            let deadline = UInt32(Int64(shard) + delta)
            let state = try TOSQuantumSelfPayState.parse(identity.wallet.initialData)
            let policy = try TOSRPCOrdinaryBOC.decode(observation.network.provenConfigParam(48).base64EncodedString())
            let request = try TOSQuantumSelfPayRequest(wallet: identity.address, state: state, role: .primary,
                validUntil: deadline, action: .execute(payment.intent.actions()), provenTime: deadline - 1, primaryPolicy: policy)
            let entry = try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false)
            if phase != .reserved {
                let signing = try outbox.beginSigning(entry)
                if phase != .signing {
                    try outbox.finishSigning(signing, signature: TOSQuantumSigner.sign(role: .primary, purpose: .selfPay,
                        seed: Data(repeating: 0x11, count: 32), expectedPublicKey: entry.signingPublicKey, digest: entry.requestHash))
                    if phase == .submitting || phase == .unknown {
                        _ = try outbox.beginSubmission(entry)
                        if phase == .unknown { try outbox.markUnknown(entry) }
                    }
                }
            }
            return try XCTUnwrap(outbox.pending(identity: identity))
        }
        func coordinator() -> TOSQuantumPaymentCoordinator {
            TOSQuantumPaymentCoordinator(outbox: outbox, baseDirectory: base, transport: { _ in self.query }, signer: { entry, id, context in
                XCTAssertEqual(id, self.id); XCTAssertEqual(context.network, self.identity.wallet.initialAuthority.namespace)
                XCTAssertEqual(try self.outbox.pending(identity: self.identity)?.phase, .signing)
                self.signs += 1; self.onSign?()
                // Public test fixture seed only; real coordinator uses protected custody.
                return try TOSQuantumSigner.sign(role: entry.role, purpose: .selfPay, seed: Data(repeating: 0x11, count: 32),
                    expectedPublicKey: entry.signingPublicKey, digest: entry.requestHash)
            }, broadcaster: { bytes, _ in
                XCTAssertFalse(Thread.isMainThread)
                let stored = try XCTUnwrap(self.outbox.pending(identity: self.identity))
                XCTAssertEqual(stored.phase, .submitting); XCTAssertNotNil(stored.feeApproval)
                XCTAssertEqual(bytes, stored.signedBOC)
                self.sends.append(bytes); try self.onBroadcast?()
            }, now: { let value = self.clock; self.onNowRead?(); return value })
        }
    }

    private func changed(_ entry: TOSQuantumOutbox.Entry, _ change: (inout [String: Any]) throws -> Void) throws -> TOSQuantumOutbox.Entry {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        try change(&value)
        return try JSONDecoder().decode(TOSQuantumOutbox.Entry.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testFreshExpiryCapabilityUsesStrictShardDeadlineAcrossEveryCanonicalPhase() async throws {
        for phase in [TOSQuantumOutbox.Phase.reserved, .signing, .signed, .submitting, .unknown] {
            for delta: Int64 in [-1, 0, 1] {
                let f = try Fixture(), entry = try f.expiryEntry(delta: delta, phase: phase)
                let deadline = try TOSQuantumStoredRequest(entry: entry).deadline
                if delta < 0 {
                    let capability = try await f.expiries().read(wallet: f.wallet())
                    XCTAssertEqual(capability.operationID, entry.id); XCTAssertEqual(capability.deadline, deadline)
                    XCTAssertGreaterThan(capability.provenShardTime, deadline)
                    try capability.requireBound(to: entry, now: f.clock)
                } else {
                    do { _ = try await f.expiries().read(wallet: f.wallet()); XCTFail("Nonexpired shard time minted expiry") } catch { }
                }
                XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.id, entry.id)
                XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.phase, phase)
                XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.signedBOC, entry.signedBOC)
                XCTAssertEqual(f.signs, 0); XCTAssertTrue(f.sends.isEmpty)
            }
        }
    }

    func testExpiryCapabilityBindsMissingBOCAndRefusesLaterSignatureAndStaleProof() async throws {
        let f = try Fixture(), entry = try f.expiryEntry(phase: .signing)
        XCTAssertNil(entry.signature); XCTAssertNil(entry.signedBOC)
        let capability = try await f.expiries().read(wallet: f.wallet())
        try capability.requireBound(to: entry, now: f.clock)
        try f.outbox.finishSigning(entry, signature: TOSQuantumSigner.sign(role: .primary, purpose: .selfPay,
            seed: Data(repeating: 0x11, count: 32), expectedPublicKey: entry.signingPublicKey, digest: entry.requestHash))
        let signed = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        XCTAssertNotNil(signed.signedBOC)
        XCTAssertThrowsError(try capability.requireBound(to: signed, now: f.clock))
        let refreshed = try await f.expiries().read(wallet: f.wallet())
        try refreshed.requireBound(to: signed, now: f.clock)
        f.clock += 301
        XCTAssertThrowsError(try refreshed.requireBound(to: signed, now: f.clock))
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.signedBOC, signed.signedBOC)
    }

    func testExpiryAndReceiptBindingCoversCompleteAuthorizationAndProfile() async throws {
        let f = try Fixture(), entry = try f.expiryEntry(phase: .signed)
        let capability = try await f.expiries().read(wallet: f.wallet())
        let binding = try TOSQuantumAuthorizationBinding(entry)
        let mutations: [(String, (inout [String: Any]) throws -> Void)] = [
            ("operation", { $0["id"] = UUID().uuidString }),
            ("birth identity", { value in
                let wallet = try TOSQuantumSelfPayWallet(authority: entry.identity.wallet.initialAuthority, walletID: 1)
                value["identity"] = try TOSQuantumSelfPayIdentity(wallet: wallet).toBOC().base64EncodedString()
            }),
            ("phase", { $0["phase"] = "unknown" }),
            ("deploy", { $0["deploy"] = !entry.deploy }),
            ("missing BOC", { $0.removeValue(forKey: "signedBOC") }),
            ("BOC bytes", { $0["signedBOC"] = Data(repeating: 0, count: 16).base64EncodedString() }),
            ("signature", { $0["signature"] = Data(repeating: 0, count: entry.role.signatureSize).base64EncodedString() }),
            ("profile", { value in
                var profile = try XCTUnwrap(value["profile"] as? [String: Any])
                profile["rootHash"] = String(repeating: "24", count: 32); value["profile"] = profile
            })
        ]
        for (name, mutation) in mutations {
            let altered = try changed(entry, mutation)
            XCTAssertThrowsError(try binding.requireSame(altered), name)
            XCTAssertThrowsError(try capability.requireBound(to: altered, now: f.clock), name)
        }
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.signedBOC, entry.signedBOC)
    }

    func testLocalClockAndDamagedOrPendingProofCannotMintExpiry() async throws {
        let f = try Fixture(), entry = try f.expiryEntry(delta: 1, phase: .unknown)
        f.clock += 121
        do { _ = try await f.expiries().read(wallet: f.wallet()); XCTFail("Local clock replaced proven shard expiry") } catch { }
        let damaged = try Fixture(); _ = try damaged.expiryEntry()
        do { _ = try await damaged.expiries(corruptProof: true).read(wallet: damaged.wallet()); XCTFail("Damaged proof minted expiry") } catch { }
        XCTAssertEqual(damaged.corruptedProofs, 1)
        let pending = f.base.appendingPathComponent("outbox/" + UUID().uuidString + ".pending")
        try JSONEncoder().encode(entry).write(to: pending)
        do { _ = try await f.expiries().read(wallet: f.wallet()); XCTFail("Uncertain write was bypassed") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertTrue(f.sends.isEmpty)
    }

    func testStrictStoredRequestRejectsTrailingPayloadAndUnknownKindBeforeExpiry() async throws {
        let f = try Fixture(), entry = try f.expiryEntry()
        let parsed = try TOSQuantumStoredRequest(entry: entry)
        let root = try TOSRPCOrdinaryBOC.decode(entry.requestBOC.base64EncodedString())
        func request(kind: UInt8 = 0, payload: Cell, extraBit: Bool = false, extraRef: Bool = false,
                     deadline: UInt32? = nil, nonce: UInt64? = nil) throws -> Cell {
            let b = try Builder().store(uint: 0x51535031, bits: 32).store(int: f.profile.globalID, bits: 32)
                .store(data: f.identity.wallet.initialAuthority.namespace).store(f.identity.address).store(data: parsed.authorityHash)
                .store(uint: entry.role.rawValue, bits: 8).store(uint: parsed.epoch, bits: 64).store(uint: nonce ?? parsed.nonce, bits: 64)
                .store(uint: deadline ?? parsed.deadline, bits: 32).store(uint: kind, bits: 8).store(ref: payload)
            if extraBit { try b.store(bit: false) }; if extraRef { try b.store(ref: Builder().endCell()) }
            return try b.endCell()
        }
        let actions = try root.refs[0].beginParse().loadRef()
        let payloadTail = try Builder().store(uint: 0x45584543, bits: 32).store(bit: false).store(ref: actions).endCell()
        let payloadRefs = try Builder().store(uint: 0x45584543, bits: 32).store(ref: actions).store(ref: Builder().endCell()).endCell()
        let invalid = try [request(payload: root.refs[0], extraBit: true), request(payload: root.refs[0], extraRef: true),
                           request(kind: 2, payload: root.refs[0]), request(payload: payloadTail), request(payload: payloadRefs),
                           request(payload: root.refs[0], deadline: 0), request(payload: root.refs[0], nonce: UInt64.max)]
        for cell in invalid {
            let altered = try changed(entry) { value in
                value["requestBOC"] = try cell.toBoc().base64EncodedString(); value["requestHash"] = cell.hash().base64EncodedString()
            }
            XCTAssertThrowsError(try TOSQuantumStoredRequest(entry: altered))
            XCTAssertThrowsError(try TOSQuantumAuthorizationBinding(altered))
            let name = f.identity.cell.hash().map { String(format: "%02x", $0) }.joined() + ".json"
            let canonical = f.base.appendingPathComponent("outbox/" + name)
            try JSONEncoder().encode(altered).write(to: canonical)
            XCTAssertThrowsError(try f.outbox.pending(identity: f.identity), "Canonical reads must use the strict parser")
            try JSONEncoder().encode(entry).write(to: canonical)
        }
    }

    func testStrictStoredRequestPreservesAllRescueActionsAndRejectsOriginalEpochSaturation() throws {
        for index in 0..<4 {
            let f = try Fixture(), payment = try f.payment()
            let state = try TOSQuantumSelfPayState.parse(f.identity.wallet.initialData)
            let observation = try TOSQuantumAccountReader(baseDirectory: f.base, transport: { f.query }, now: { f.clock })
                .observeEnrolled(id: f.id, identity: f.identity, profile: f.profile, configIndices: [8, 19, 48])
            let policy = try TOSRPCOrdinaryBOC.decode(observation.network.provenConfigParam(48).base64EncodedString())
            let time = try observation.proof.provenAccountTime(expectedAddress: f.identity.address.toRaw())
            let actions: [TOSQuantumSelfPayAction] = [.execute(try payment.intent.actions()), .configureRequired,
                                                    .lockPrimary, .migrate(state.authority)]
            let original = try TOSQuantumSelfPayRequest(wallet: f.identity.address, state: state, role: .rescue,
                validUntil: time - 1, action: actions[index], provenTime: time - 2, primaryPolicy: policy)
            let entry = try f.outbox.reserve(identity: f.identity, profile: f.profile, request: original, deploy: false)
            let parsed = try TOSQuantumStoredRequest(entry: entry)
            XCTAssertEqual(parsed.kind, [UInt8(0), 1, 3, 4][index])
            if parsed.kind != 0 {
                let saturated = try Builder().store(uint: 0x51535031, bits: 32).store(int: f.profile.globalID, bits: 32)
                    .store(data: state.authority.namespace).store(f.identity.address).store(data: parsed.authorityHash)
                    .store(uint: entry.role.rawValue, bits: 8).store(uint: UInt64.max, bits: 64).store(uint: parsed.nonce, bits: 64)
                    .store(uint: parsed.deadline, bits: 32).store(uint: parsed.kind, bits: 8).store(ref: original.request.refs[0]).endCell()
                let altered = try changed(entry) { value in
                    value["requestBOC"] = try saturated.toBoc().base64EncodedString(); value["requestHash"] = saturated.hash().base64EncodedString()
                }
                XCTAssertThrowsError(try TOSQuantumStoredRequest(entry: altered))
            }
        }
    }

    func testExpiryRereadsPhaseAndSharesIdentityPermitWithReceiptReader() async throws {
        let changedFixture = try Fixture(), reserved = try changedFixture.expiryEntry()
        var phaseChanged = false
        do {
            _ = try await changedFixture.expiries(beforeProof: { _ in
                if !phaseChanged { phaseChanged = true; _ = try? changedFixture.outbox.beginSigning(reserved) }
            }).read(wallet: changedFixture.wallet())
            XCTFail("A phase change while authenticating was accepted")
        } catch { }
        XCTAssertTrue(phaseChanged)
        XCTAssertEqual(try changedFixture.outbox.pending(identity: changedFixture.identity)?.phase, .signing)
        let f = try Fixture(); let entry = try f.expiryEntry(phase: .signed)
        let entered = expectation(description: "Expiry proof query entered"), resume = DispatchSemaphore(value: 0)
        var first = true
        let task = Task {
            try await f.expiries(beforeProof: { _ in
                if first { first = false; entered.fulfill(); resume.wait() }
            }).read(wallet: f.wallet())
        }
        await fulfillment(of: [entered], timeout: 10)
        do { _ = try await f.outcomes().read(wallet: f.wallet()); XCTFail("Receipt and expiry workers overlapped one identity") }
        catch { guard case TOSQuantumAccountReader.Error.busy = error else { resume.signal(); return XCTFail("Wrong refusal: \(error)") } }
        task.cancel(); resume.signal()
        do { _ = try await task.value; XCTFail("Cancelled expiry yielded a capability") } catch { }
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.signedBOC, entry.signedBOC)
        XCTAssertTrue(f.sends.isEmpty)
    }

    func testAuthorizationBindingIsStableAcrossIdentityBOCReencodingAndRejectsChangedOriginalBytes() async throws {
        let f = try Fixture(), entry = try f.expiryEntry(phase: .signed)
        let binding = try TOSQuantumAuthorizationBinding(entry)
        let capability = try await f.expiries().read(wallet: f.wallet())
        let identityAlternate = try entry.identity.cell.toBoc(crc32: false)
        XCTAssertEqual(try TOSQuantumSelfPayIdentity(boc: identityAlternate), entry.identity)
        for _ in 0..<32 {
            let redecoded = try changed(entry) { $0["identity"] = identityAlternate.base64EncodedString() }
            try binding.requireSame(redecoded)
            try capability.requireBound(to: redecoded, now: f.clock)
            let disk = try XCTUnwrap(f.outbox.pending(identity: f.identity))
            try binding.requireSame(disk)
        }
        let request = try TOSRPCOrdinaryBOC.decode(entry.requestBOC.base64EncodedString())
        let requestAlternate = try request.toBoc(crc32: false)
        XCTAssertNotEqual(requestAlternate, entry.requestBOC)
        XCTAssertEqual(try TOSRPCOrdinaryBOC.decode(requestAlternate.base64EncodedString()).hash(), entry.requestHash)
        let otherRequestBytes = try changed(entry) { $0["requestBOC"] = requestAlternate.base64EncodedString() }
        XCTAssertThrowsError(try binding.requireSame(otherRequestBytes))
        XCTAssertThrowsError(try capability.requireBound(to: otherRequestBytes, now: f.clock))
        let originalMessage = try XCTUnwrap(entry.signedBOC)
        let external = try TOSRPCOrdinaryBOC.decode(originalMessage.base64EncodedString())
        let externalAlternate = try external.toBoc(crc32: false)
        XCTAssertNotEqual(externalAlternate, originalMessage)
        XCTAssertEqual(try TOSRPCOrdinaryBOC.decode(externalAlternate.base64EncodedString()).hash(), external.hash())
        let otherMessageBytes = try changed(entry) { $0["signedBOC"] = externalAlternate.base64EncodedString() }
        XCTAssertThrowsError(try binding.requireSame(otherMessageBytes))
        XCTAssertThrowsError(try capability.requireBound(to: otherMessageBytes, now: f.clock))
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.signedBOC, entry.signedBOC)
    }

    func testRestartRecoveryReestimatesOnlyTheOriginalSignedAuthorization() async throws {
        let f = try Fixture(), coordinator = f.coordinator()
        let original = try await coordinator.authorizeAndEstimate(f.payment(comment: "Recover exact message"))
        let stored = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        f.clock += 31
        let restarted = f.coordinator()
        let quote = try await restarted.recoverAndEstimate(wallet: f.wallet())
        XCTAssertEqual(quote.operationID, original.operationID)
        XCTAssertEqual(quote.intent, original.intent)
        XCTAssertEqual(f.signs, 1); XCTAssertTrue(f.sends.isEmpty)
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.requestBOC, stored.requestBOC)
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.signedBOC, stored.signedBOC)
        try await restarted.submit(quote)
        XCTAssertEqual(f.sends, [try XCTUnwrap(stored.signedBOC)])
        XCTAssertEqual(f.signs, 1)
    }

    func testRestartRecoveryRefusesExpiredOriginalRequestAndKeepsItsSlot() async throws {
        let f = try Fixture()
        _ = try await f.coordinator().authorizeAndEstimate(f.payment())
        let stored = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        f.clock += 121
        do { _ = try await f.coordinator().recoverAndEstimate(wallet: f.wallet()); XCTFail("Expired request was replaced during recovery") }
        catch { guard case TOSQuantumPreparedPayment.Error.expired = error else { return XCTFail("Wrong refusal: \(error)") } }
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.id, stored.id)
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.signedBOC, stored.signedBOC)
        XCTAssertEqual(f.signs, 1); XCTAssertTrue(f.sends.isEmpty)
    }

    func testRestartEstimateDoesNotReplayAnUnknownSubmission() async throws {
        let f = try Fixture(), coordinator = f.coordinator()
        let quote = try await coordinator.authorizeAndEstimate(f.payment())
        try await coordinator.submit(quote)
        let stored = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        do { _ = try await coordinator.recoverAndEstimate(wallet: f.wallet()); XCTFail("Unknown submission was treated as an unbroadcast signature") }
        catch { guard case TOSQuantumPaymentCoordinator.Error.missingEntry = error else { return XCTFail("Wrong refusal: \(error)") } }
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.signedBOC, stored.signedBOC)
        XCTAssertEqual(f.signs, 1); XCTAssertEqual(f.sends.count, 1)
    }

    func testAppJournalActionsOnlyDiscardUnsignedMatchingOperation() async throws {
        let f = try Fixture(), coordinator = f.coordinator()
        let emptyBefore = try await coordinator.pending(wallet: f.wallet())
        XCTAssertNil(emptyBefore)
        let reserved = try f.outbox.reserve(payment: f.payment(), now: f.clock)
        let loaded = try await coordinator.pending(wallet: f.wallet())
        XCTAssertEqual(loaded?.id, reserved.id)
        do { try await coordinator.cancelUnsigned(wallet: f.wallet(), operationID: UUID()); XCTFail("Another operation cancelled") } catch { }
        try await coordinator.cancelUnsigned(wallet: f.wallet(), operationID: reserved.id)
        let emptyAfter = try await coordinator.pending(wallet: f.wallet())
        XCTAssertNil(emptyAfter)
        _ = try await coordinator.authorizeAndEstimate(f.payment())
        let signed = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        do { try await coordinator.cancelUnsigned(wallet: f.wallet(), operationID: signed.id); XCTFail("Signed authorization cancelled") } catch { }
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.signedBOC, signed.signedBOC)
    }

    func testNativeQuoteUsesFullBalanceDeductionAndPersistsBeforeBroadcastAndRetry() async throws {
        let f = try Fixture(), coordinator = f.coordinator(), payment = try f.payment()
        let quote = try await coordinator.authorizeAndEstimate(payment)
        XCTAssertEqual(f.signs, 1); XCTAssertTrue(f.sends.isEmpty)
        XCTAssertEqual(quote.observedBalance, 1_000_000_000_000_000)
        // This Swift message uses a relaxed source/zero creation fields and an
        // inline empty body; the earlier host fixture used explicit source/time.
        XCTAssertEqual(quote.estimatedFee, 1_809_796)
        XCTAssertGreaterThan(quote.estimatedFee, quote.transactionFees,
            "total_fees alone undercounts this actual native execution")
        XCTAssertEqual(quote.expiresAt, UInt32(f.clock + 30))
        XCTAssertEqual(quote.estimatedDebit, payment.intent.amount + quote.estimatedFee)
        XCTAssertEqual(quote.estimatedBalance, quote.observedBalance - quote.estimatedDebit)
        let stored = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        XCTAssertEqual(stored.phase, .signed); XCTAssertNil(stored.feeApproval)
        XCTAssertThrowsError(try f.outbox.beginSubmission(stored), "Payment bypassed quote confirmation")
        enum RelayFailure: Error { case responseLost }
        f.onBroadcast = { throw RelayFailure.responseLost }
        do { try await coordinator.submit(quote); XCTFail("Lost response was reported as success") }
        catch { XCTAssertTrue(error is RelayFailure) }
        let unknown = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        XCTAssertEqual(unknown.phase, .unknown)
        XCTAssertEqual(unknown.feeApproval?.estimatedFee, String(quote.estimatedFee))
        f.onBroadcast = nil
        try await coordinator.submit(quote)
        XCTAssertEqual(f.sends.count, 2); XCTAssertEqual(f.sends[0], f.sends[1]); XCTAssertEqual(f.signs, 1)
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.phase, .unknown)
        XCTAssertThrowsError(try f.outbox.cancelUnsigned(stored))
    }

    func testOutcomeReaderRestartsFromDurableEntryAndKeepsUnverifiedSlot() async throws {
        let f = try Fixture(), coordinator = f.coordinator()
        let quote = try await coordinator.authorizeAndEstimate(f.payment())
        try await coordinator.submit(quote)
        let stored = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        let page = try await f.outcomes().read(wallet: f.wallet())
        XCTAssertEqual(page.operationID, stored.id)
        XCTAssertEqual(page.scannedCount, 0); XCTAssertNil(page.receipt); XCTAssertNil(page.next)
        XCTAssertFalse(page.authorizationExpired)
        let after = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        XCTAssertEqual(after.phase, .unknown); XCTAssertEqual(after.signedBOC, stored.signedBOC)
        XCTAssertEqual(f.signs, 1); XCTAssertEqual(f.sends.count, 1)
    }

    func testOutcomeExpiryUsesProvenShardTimeAndNeverReleasesAuthorization() async throws {
        for expectedExpired in [false, true] {
            let f = try Fixture(), payment = try f.payment()
            let state = try TOSQuantumSelfPayState.parse(f.identity.wallet.initialData)
            let accounts = TOSQuantumAccountReader(baseDirectory: f.base, transport: { f.query }, now: { f.clock })
            let observation = try accounts.observeEnrolled(id: f.id, identity: f.identity, profile: f.profile, configIndices: [8, 19, 48])
            let policy = try TOSRPCOrdinaryBOC.decode(observation.network.provenConfigParam(48).base64EncodedString())
            let time = try observation.proof.provenAccountTime(expectedAddress: f.identity.address.toRaw())
            let deadline = expectedExpired ? time - 1 : time
            let request = try TOSQuantumSelfPayRequest(wallet: f.identity.address, state: state, role: .primary,
                validUntil: deadline, action: .execute(payment.intent.actions()), provenTime: deadline - 1, primaryPolicy: policy)
            let entry = try f.outbox.reserve(identity: f.identity, profile: f.profile, request: request, deploy: false,
                paymentIntent: payment.intent)
            try f.outbox.signReserved(entry) { stored in
                try TOSQuantumSigner.sign(role: .primary, purpose: .selfPay, seed: Data(repeating: 0x11, count: 32),
                    expectedPublicKey: stored.signingPublicKey, digest: stored.requestHash)
            }
            let page = try await f.outcomes().read(wallet: f.wallet())
            XCTAssertEqual(page.provenShardTime, time)
            XCTAssertEqual(page.authorizationExpired, expectedExpired); XCTAssertNil(page.receipt)
            XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.id, entry.id)
            XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.phase, .signed)
        }
    }

    func testLocalClockExpiryCannotReplaceProvenExpiryOrReleaseSlot() async throws {
        let f = try Fixture()
        _ = try await f.coordinator().authorizeAndEstimate(f.payment())
        let entry = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        f.clock += 121
        let page = try await f.outcomes().read(wallet: f.wallet())
        XCTAssertFalse(page.authorizationExpired); XCTAssertNil(page.receipt)
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.id, entry.id)
        XCTAssertEqual(f.signs, 1); XCTAssertTrue(f.sends.isEmpty)
    }

    func testOutcomeReaderRejectsUnsignedInterruptedSigningAndDamagedAccountProof() async throws {
        let f = try Fixture(), payment = try f.payment()
        let entry = try f.outbox.reserve(payment: payment, now: f.clock)
        _ = try f.outbox.beginSigning(entry)
        do { _ = try await f.outcomes().read(wallet: f.wallet()); XCTFail("Unknown signer result reconciled without BOC") }
        catch { guard case TOSQuantumPaymentOutcomeReader.Error.missingSignedPayment = error else { return XCTFail("Wrong error: \(error)") } }
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.phase, .signing)
        let signed = try Fixture()
        _ = try await signed.coordinator().authorizeAndEstimate(signed.payment())
        do { _ = try await signed.outcomes(corruptProof: true).read(wallet: signed.wallet()); XCTFail("Damaged proof accepted") }
        catch { }
        XCTAssertEqual(signed.corruptedProofs, 1, "Refusal must actually reach the damaged account proof")
        XCTAssertEqual(try signed.outbox.pending(identity: signed.identity)?.phase, .signed)
        XCTAssertTrue(signed.sends.isEmpty)
    }

    func testOutcomeReaderRejectsConcurrentAliasesAndCancellationPreservesAuthorization() async throws {
        let f = try Fixture()
        _ = try await f.coordinator().authorizeAndEstimate(f.payment())
        let stored = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        let entered = expectation(description: "Proof query entered"), resume = DispatchSemaphore(value: 0)
        let lock = NSLock(); var first = true
        let reader = f.outcomes(beforeProof: { _ in
            let shouldWait = lock.withLock { let value = first; first = false; return value }
            if shouldWait { entered.fulfill(); _ = resume.wait(timeout: .now() + 20) }
        })
        let otherID = UUID()
        try TOSQuantumCreationRecord(id: otherID, profile: f.profile, identity: f.identity).save(baseDirectory: f.base)
        let session = try TOSQuantumProofSession(walletID: otherID, locallyProvisionedAnchor: f.profile.anchor(), baseDirectory: f.base)
        let request = try JSONSerialization.data(withJSONObject: ["mode":"live", "max_age_seconds":300, "config_params":[8,19,48]])
        let material = try [(1,"masterchain-info.tl"), (2,"chain-0000.tl"), (4,"exec-config.tl")].map { kind, name in
            TOSQuantumProofBridge.Material(kind: UInt32(kind), bytes: try Data(contentsOf: f.assets.appendingPathComponent("material/" + name)))
        }
        _ = try session.enroll(request: request, now: f.clock, material: material)
        let work = Task { try await reader.read(wallet: f.wallet()) }
        await fulfillment(of: [entered], timeout: 10)
        let original = f.wallet()
        let alias = Wallet(id: otherID.uuidString, identity: original.identity, metaData: original.metaData,
            setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
        do { _ = try await f.outcomes().read(wallet: alias); XCTFail("Alias bypassed the birth-identity read permit") }
        catch { guard case TOSQuantumAccountReader.Error.busy = error else { resume.signal(); return XCTFail("Wrong refusal: \(error)") } }
        work.cancel(); resume.signal()
        do { _ = try await work.value; XCTFail("Cancelled proof published a result") } catch { }
        let restored = try await f.outcomes().read(wallet: f.wallet())
        XCTAssertNil(restored.receipt)
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.id, stored.id)
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.signedBOC, stored.signedBOC)
        XCTAssertEqual(f.signs, 1); XCTAssertTrue(f.sends.isEmpty)
    }

    func testExpiredQuoteNeverBroadcastsOrReleasesSignedAuthorization() async throws {
        let f = try Fixture(), coordinator = f.coordinator()
        let quote = try await coordinator.authorizeAndEstimate(f.payment())
        f.clock += 31
        do { try await coordinator.submit(quote); XCTFail("Stale quote submitted") }
        catch { XCTAssertTrue(error is TOSPQError) }
        XCTAssertTrue(f.sends.isEmpty); XCTAssertEqual(f.signs, 1)
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.phase, .signed)
        let before = try XCTUnwrap(f.outbox.pending(identity: f.identity)?.signedBOC)
        let refreshed = try await coordinator.refresh(quote)
        XCTAssertEqual(refreshed.operationID, quote.operationID)
        XCTAssertEqual(refreshed.expiresAt, UInt32(f.clock + 30))
        try await coordinator.submit(refreshed)
        XCTAssertEqual(f.signs, 1); XCTAssertEqual(f.sends, [before])
    }

    func testSuccessfulVMWithSkippedSendCannotProduceFeeConfirmation() async throws {
        let f = try Fixture(), coordinator = f.coordinator()
        let payment = try f.payment(amount: 1_000_000_000_000_000)
        do { _ = try await coordinator.authorizeAndEstimate(payment); XCTFail("Skipped output quoted as payment") }
        catch { guard case TOSQuantumPaymentQuote.Error.notExecutable = error else { return XCTFail("Wrong refusal: \(error)") } }
        XCTAssertEqual(f.signs, 1); XCTAssertTrue(f.sends.isEmpty)
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.phase, .signed)
    }

    func testUncertainStorageRefusesTransportAfterQuote() async throws {
        let f = try Fixture(), coordinator = f.coordinator()
        let quote = try await coordinator.authorizeAndEstimate(f.payment(comment: "付款🌸"))
        let orphan = f.base.appendingPathComponent("outbox/interrupted.pending")
        try Data([1]).write(to: orphan)
        do { try await coordinator.submit(quote); XCTFail("Uncertain write allowed broadcast") }
        catch { guard case TOSQuantumOutbox.Error.storage = error else { return XCTFail("Wrong refusal: \(error)") } }
        XCTAssertTrue(f.sends.isEmpty)
        try FileManager.default.removeItem(at: orphan)
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.phase, .signed)
    }

    func testConcurrentConfirmationCannotSignTwiceAndCancellationKeepsSignedBytes() async throws {
        let f = try Fixture(), coordinator = f.coordinator(), payment = try f.payment()
        let entered = expectation(description: "Signer entered"), resume = DispatchSemaphore(value: 0)
        f.onSign = { entered.fulfill(); _ = resume.wait(timeout: .now() + 20) }
        let first = Task { try await coordinator.authorizeAndEstimate(payment) }
        await fulfillment(of: [entered], timeout: 10)
        do { _ = try await coordinator.authorizeAndEstimate(payment); XCTFail("Second signer admitted") }
        catch { guard case TOSQuantumAccountReader.Error.busy = error else { resume.signal(); return XCTFail("Wrong refusal: \(error)") } }
        first.cancel(); resume.signal()
        do { _ = try await first.value; XCTFail("Cancelled preview returned") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(f.signs, 1); XCTAssertTrue(f.sends.isEmpty)
        let entry = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        XCTAssertEqual(entry.phase, .signed); XCTAssertNotNil(entry.signedBOC)
        XCTAssertThrowsError(try f.outbox.cancelUnsigned(entry))
    }

    func testCancellationDuringBroadcastRetainsUnknownAndConfirmedBytes() async throws {
        let f = try Fixture(), coordinator = f.coordinator()
        let quote = try await coordinator.authorizeAndEstimate(f.payment())
        let entered = expectation(description: "Broadcast entered"), resume = DispatchSemaphore(value: 0)
        enum RelayFailure: Error { case stopped }
        f.onBroadcast = { entered.fulfill(); _ = resume.wait(timeout: .now() + 20); throw RelayFailure.stopped }
        let sending = Task { try await coordinator.submit(quote) }
        await fulfillment(of: [entered], timeout: 10)
        sending.cancel(); resume.signal()
        do { try await sending.value; XCTFail("Cancelled broadcast returned") }
        catch { XCTAssertTrue(error is CancellationError) }
        let entry = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        XCTAssertEqual(entry.phase, .unknown); XCTAssertNotNil(entry.feeApproval)
        XCTAssertEqual(entry.signedBOC, f.sends.first); XCTAssertEqual(f.signs, 1)
    }

    func testOldQuoteCannotConfirmAReplacementOperation() async throws {
        let f = try Fixture(), coordinator = f.coordinator()
        let quote = try await coordinator.authorizeAndEstimate(f.payment())
        let directory = f.base.appendingPathComponent("outbox")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let replacement = UUID()
        object["id"] = replacement.uuidString
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file, options: [.completeFileProtection])
        let current = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        XCTAssertEqual(current.id, replacement); XCTAssertEqual(current.phase, .signed)
        XCTAssertNotEqual(current.id, quote.operationID)
        do { try await coordinator.submit(quote); XCTFail("Old quote confirmed replacement operation") }
        catch { guard case TOSQuantumPaymentQuote.Error.binding = error else { return XCTFail("Wrong refusal: \(error)") } }
        XCTAssertTrue(f.sends.isEmpty); XCTAssertEqual(f.signs, 1)
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.phase, .signed)
    }

    func testRealStorageFailureDuringCancelledBroadcastIsNotReportedAsCancellation() async throws {
        let f = try Fixture(), coordinator = f.coordinator()
        let quote = try await coordinator.authorizeAndEstimate(f.payment())
        let directory = f.base.appendingPathComponent("outbox")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let entered = expectation(description: "Durable broadcast entered"), resume = DispatchSemaphore(value: 0)
        enum RelayFailure: Error { case responseLost }
        f.onBroadcast = { entered.fulfill(); _ = resume.wait(timeout: .now() + 20); throw RelayFailure.responseLost }
        let sending = Task { try await coordinator.submit(quote) }
        await fulfillment(of: [entered], timeout: 10)
        // Existing .lock can still be opened and the directory enumerated, but
        // Data.write cannot create the next private .pending file.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        sending.cancel(); resume.signal()
        do { try await sending.value; XCTFail("Uncertain storage returned success") }
        catch {
            let failure = error as NSError
            XCTAssertEqual(failure.domain, NSCocoaErrorDomain, "Cancellation masked the actual durable-write error")
            XCTAssertEqual(failure.code, NSFileWriteNoPermissionError)
        }
        XCTAssertEqual(f.sends.count, 1); XCTAssertEqual(f.signs, 1)
        let entry = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        XCTAssertEqual(entry.phase, .submitting); XCTAssertNotNil(entry.feeApproval)
        XCTAssertEqual(entry.signedBOC, f.sends.first)
    }

    func testQuoteExpiryDuringPersistenceIsRecheckedBeforeBroadcast() async throws {
        let f = try Fixture(), coordinator = f.coordinator()
        let quote = try await coordinator.authorizeAndEstimate(f.payment())
        var advanced = false
        f.onNowRead = { [weak f] in
            guard let f, !advanced else { return }
            // beginPaymentSubmission receives its previously read timestamp;
            // represent time passing while waiting for its lock/fsync.
            advanced = true; f.clock += 31
        }
        do { try await coordinator.submit(quote); XCTFail("Quote expired during persistence was submitted") }
        catch { XCTAssertTrue(error is TOSPQError) }
        XCTAssertTrue(advanced); XCTAssertTrue(f.sends.isEmpty)
        let entry = try XCTUnwrap(f.outbox.pending(identity: f.identity))
        XCTAssertEqual(entry.phase, .unknown); XCTAssertNotNil(entry.feeApproval)
        XCTAssertEqual(f.signs, 1)
    }
}
