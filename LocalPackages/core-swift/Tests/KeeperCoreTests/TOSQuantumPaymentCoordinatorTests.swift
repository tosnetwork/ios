import XCTest
import Darwin
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
        func outcomes(store: TOSQuantumOutbox? = nil, corruptProof: Bool = false, beforeProof: ((TOSQuantumHistoryReader.StopFlag) -> Void)? = nil) -> TOSQuantumPaymentOutcomeReader {
            TOSQuantumPaymentOutcomeReader(outbox: store ?? outbox, baseDirectory: base, accounts: { flag in
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
        func expiries(store: TOSQuantumOutbox? = nil, corruptProof: Bool = false, beforeProof: ((TOSQuantumHistoryReader.StopFlag) -> Void)? = nil) -> TOSQuantumAuthorizationExpiryReader {
            TOSQuantumAuthorizationExpiryReader(outbox: store ?? outbox, baseDirectory: base, accounts: { flag in
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
        func expiryEntry(delta: Int64 = -1, phase: TOSQuantumOutbox.Phase = .reserved, withPaymentIntent: Bool = false) throws -> TOSQuantumOutbox.Entry {
            let payment = try payment()
            let observation = try TOSQuantumAccountReader(baseDirectory: base, transport: { self.query }, now: { self.clock })
                .observeEnrolled(id: id, identity: identity, profile: profile, configIndices: [8, 19, 48])
            let shard = try observation.proof.provenAccountTime(expectedAddress: identity.address.toRaw())
            let deadline = UInt32(Int64(shard) + delta)
            let state = try TOSQuantumSelfPayState.parse(identity.wallet.initialData)
            let policy = try TOSRPCOrdinaryBOC.decode(observation.network.provenConfigParam(48).base64EncodedString())
            let request = try TOSQuantumSelfPayRequest(wallet: identity.address, state: state, role: .primary,
                validUntil: deadline, action: .execute(payment.intent.actions()), provenTime: deadline - 1, primaryPolicy: policy)
            let entry = try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false,
                                           paymentIntent: withPaymentIntent ? payment.intent : nil)
            if phase != .reserved {
                let signing = try outbox.beginSigning(entry)
                if phase != .signing {
                    try outbox.finishSigning(signing, signature: TOSQuantumSigner.sign(role: .primary, purpose: .selfPay,
                        seed: Data(repeating: 0x11, count: 32), expectedPublicKey: entry.signingPublicKey, digest: entry.requestHash))
                    if phase == .submitting || phase == .unknown {
                        if withPaymentIntent {
                            // Captured-state fixture, not a product broadcast bypass:
                            // expiry is already past, so no valid fee quote can exist.
                            let signed = try XCTUnwrap(outbox.pending(identity: identity))
                            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(signed)) as? [String: Any])
                            value["phase"] = phase.rawValue
                            let name = identity.cell.hash().map { String(format: "%02x", $0) }.joined() + ".json"
                            try JSONSerialization.data(withJSONObject: value).write(to: base.appendingPathComponent("outbox/" + name))
                        } else {
                            _ = try outbox.beginSubmission(entry)
                            if phase == .unknown { try outbox.markUnknown(entry) }
                        }
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

    private func retirementSource(_ fixture: Fixture, store: TOSQuantumOutbox, operationID: UUID) throws -> TOSQuantumOutbox.RetirementSource {
        guard case .authorization(let source, _) = try store.inspectRetirement(identity: fixture.identity, profile: fixture.profile, operationID: operationID) else {
            throw TOSQuantumOutbox.Error.invalidTransition
        }
        return source
    }
    private func canonicalFile(_ fixture: Fixture) -> URL {
        fixture.base.appendingPathComponent("outbox/" + fixture.identity.cell.hash().map { String(format: "%02x", $0) }.joined() + ".json")
    }
    private enum RetirementCrash: Swift.Error { case injected }

    func testDirectoryReadErrorAfterPartialReadIsNotEOFAndNeverReachesSigner() throws {
        let f = try Fixture(), entry = try f.expiryEntry()
        let canonical = canonicalFile(f), original = try Data(contentsOf: canonical)
        let pending = f.base.appendingPathComponent("outbox/" + UUID().uuidString + ".pending")
        let uncertain = Data("unknown unfinished authorization".utf8)
        try uncertain.write(to: pending); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
        var injected = false, partialCount = 0, signerCalls = 0
        let failing = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"), directoryReadFailure: { folder, count in
            if folder.lastPathComponent == "outbox", count >= 1, !injected {
                injected = true; partialCount = count; return EIO
            }
            return nil
        })
        do {
            try failing.signReserved(entry) { _ in signerCalls += 1; return Data() }
            XCTFail("A partial readdir error authorized signing")
        } catch {
            let failure = error as NSError
            XCTAssertEqual(failure.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(failure.code, Int(EIO), "Must reach the readdir(nil, errno) rejection, not a pre-call throw")
        }
        XCTAssertTrue(injected); XCTAssertGreaterThanOrEqual(partialCount, 1)
        XCTAssertEqual(signerCalls, 0)
        XCTAssertEqual(try Data(contentsOf: canonical), original)
        XCTAssertEqual(try Data(contentsOf: pending), uncertain)
        let diagnostic = XCTAttachment(string: "readdir returned nil with injected errno=EIO after \(partialCount) real names; canonical/pending bytes unchanged; signer calls=0")
        diagnostic.name = "retirement-readdir-error-path"; diagnostic.lifetime = .keepAlways; add(diagnostic)
    }

    func testRetirementEveryPublicationDeletionAndCleanupWindowRestartsSafely() async throws {
        let excluded: Set<TOSQuantumOutbox.RetirementFaultPoint> = [.stageRepairBeforeFreshCheck, .stageDiagnosticSync,
            .stageRepairSnapshotWrite, .historyPruneUnlink, .historyPruneDirectorySync]
        for point in TOSQuantumOutbox.RetirementFaultPoint.allCases where !excluded.contains(point) {
            let f = try Fixture(), entry = try f.expiryEntry(phase: .signing)
            let source = try retirementSource(f, store: f.outbox, operationID: entry.id)
            let expiry = try await f.expiries().read(wallet: f.wallet(), source: source)
            var hit = false
            let crashing = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"), retirementFault: { observed in
                if observed == point && !hit { hit = true; throw RetirementCrash.injected }
            })
            do { _ = try crashing.finishRetirement(source, expiry: expiry, receipt: nil, now: { f.clock }); XCTFail("Fault not propagated: \(point)") }
            catch { guard case RetirementCrash.injected = error else { return XCTFail("Wrong fault at \(point): \(error)") } }
            XCTAssertTrue(hit, "Unreached fault is not evidence: \(point)")
            let reopened = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"))
            switch try reopened.inspectRetirement(identity: f.identity, profile: f.profile, operationID: entry.id) {
            case .authorization(let retained, _):
                XCTAssertEqual(retained.entry.id, entry.id)
                XCTAssertEqual(retained.entry.requestBOC, entry.requestBOC)
                XCTAssertNil(retained.entry.signedBOC)
                XCTAssertThrowsError(try reopened.pending(identity: f.identity), "Unresolved retirement must block ordinary APIs")
                let refreshed = try await f.expiries(store: reopened).read(wallet: f.wallet(), source: retained)
                let summary = try reopened.finishRetirement(retained, expiry: refreshed, receipt: nil, now: { f.clock })
                XCTAssertEqual(summary.publication, .releaseCompleted); XCTAssertEqual(summary.outcome, .expiredUnverified)
            case .completed(let local):
                XCTAssertEqual(local.authorization.operationID, entry.id)
                XCTAssertEqual(local.publication, .releaseCompleted)
            case .none:
                XCTAssertTrue(try reopened.retirementHistory(identity: f.identity, profile: f.profile).contains {
                    $0.authorization.operationID == entry.id && $0.publication == .releaseCompleted
                }, "No source is valid only after durable completed cleanup: \(point)")
            }
            XCTAssertNil(try reopened.pending(identity: f.identity)); XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalFile(f).path))
            for name in ["retirement-stage", "retirement-workspace", "retirement-descriptor.json", "retirement-descriptor.next"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("outbox/" + name).path), "Cleanup debt at \(point)")
            }
            XCTAssertEqual(f.signs, 0); XCTAssertTrue(f.sends.isEmpty)
        }
    }

    func testRetirementCompletedVisibilityMustResyncBeforeDeletingOnlySnapshot() async throws {
        let f = try Fixture(), entry = try f.expiryEntry(phase: .signing)
        let source = try retirementSource(f, store: f.outbox, operationID: entry.id)
        let expiry = try await f.expiries().read(wallet: f.wallet(), source: source)
        let first = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"), retirementFault: {
            if $0 == .completedRename { throw RetirementCrash.injected }
        })
        do { _ = try first.finishRetirement(source, expiry: expiry, receipt: nil, now: { f.clock }); XCTFail("Rename crash absent") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalFile(f).path))
        let snapshot = f.base.appendingPathComponent("outbox/retirement-workspace/entry.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        var resyncReached = false
        let retry = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"), retirementFault: {
            if $0 == .cleanupHistoryDirectorySync { resyncReached = true; throw RetirementCrash.injected }
        })
        XCTAssertThrowsError(try retry.pending(identity: f.identity))
        XCTAssertTrue(resyncReached); XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        let final = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"))
        XCTAssertNil(try final.pending(identity: f.identity))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertEqual(try final.retirementHistory(identity: f.identity, profile: f.profile).first?.publication, .releaseCompleted)
    }

    func testRetirementResumeRefsyncsEntryAndDecisionBeforePublishingOrUnlinking() async throws {
        for failedWrite in [TOSQuantumOutbox.RetirementFaultPoint.snapshotWrite, .decisionWrite, .decisionFileSync] {
            let f = try Fixture(), entry = try f.expiryEntry(phase: .signing)
            let source = try retirementSource(f, store: f.outbox, operationID: entry.id)
            let expiry = try await f.expiries().read(wallet: f.wallet(), source: source)
            let first = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"), retirementFault: {
                if $0 == failedWrite { throw RetirementCrash.injected }
            })
            do { _ = try first.finishRetirement(source, expiry: expiry, receipt: nil, now: { f.clock }); XCTFail("Publication crash absent") } catch { }
            var resyncReached = false
            let retry = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"), retirementFault: {
                if $0 == .materialDecisionFileSync { resyncReached = true; throw RetirementCrash.injected }
            })
            let retained = try retirementSource(f, store: retry, operationID: entry.id)
            let refreshed = try await f.expiries(store: retry).read(wallet: f.wallet(), source: retained)
            do { _ = try retry.finishRetirement(retained, expiry: refreshed, receipt: nil, now: { f.clock }); XCTFail("Resume did not resync material") } catch { }
            XCTAssertTrue(resyncReached)
            XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalFile(f).path), "Material sync failure must precede canonical unlink")
            XCTAssertFalse(try retry.retirementHistory(identity: f.identity, profile: f.profile).contains { $0.publication == .releaseCompleted })
        }
    }

    func testRetirementCanonicalMissingUsesFullSnapshotAndFreshNativeProof() async throws {
        let f = try Fixture(), entry = try f.expiryEntry(phase: .signing)
        let raw = try Data(contentsOf: canonicalFile(f)), source = try retirementSource(f, store: f.outbox, operationID: entry.id)
        let expiry = try await f.expiries().read(wallet: f.wallet(), source: source)
        let first = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"), retirementFault: {
            if $0 == .canonicalUnlink { throw RetirementCrash.injected }
        })
        do { _ = try first.finishRetirement(source, expiry: expiry, receipt: nil, now: { f.clock }); XCTFail("Unlink crash absent") } catch { }
        let snapshot = f.base.appendingPathComponent("outbox/retirement-workspace/entry.json")
        XCTAssertEqual(try Data(contentsOf: snapshot), raw, "Snapshot must preserve actual same-FD canonical bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalFile(f).path))
        let reopened = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"))
        let retained = try retirementSource(f, store: reopened, operationID: entry.id)
        do { _ = try await f.expiries(store: reopened, corruptProof: true).read(wallet: f.wallet(), source: retained); XCTFail("Summary substituted fresh proof") } catch { }
        XCTAssertEqual(f.corruptedProofs, 1); XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        let fresh = try await f.expiries(store: reopened).read(wallet: f.wallet(), source: retained)
        let completed = try reopened.finishRetirement(retained, expiry: fresh, receipt: nil, now: { f.clock })
        XCTAssertEqual(completed.outcome, .expiredUnverified); XCTAssertNil(completed.transaction)
        XCTAssertNil(try reopened.pending(identity: f.identity)); XCTAssertEqual(f.signs, 0); XCTAssertTrue(f.sends.isEmpty)
    }

    func testRetirementRechecksFreshnessAfterDurablePendingAndOldOpCannotDeleteNewSlot() async throws {
        let f = try Fixture(), entry = try f.expiryEntry()
        let source = try retirementSource(f, store: f.outbox, operationID: entry.id)
        let expiry = try await f.expiries().read(wallet: f.wallet(), source: source)
        let delayed = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"), retirementFault: {
            if $0 == .pendingWorkspaceDirectorySync { f.clock += 301 }
        })
        do { _ = try delayed.finishRetirement(source, expiry: expiry, receipt: nil, now: { f.clock }); XCTFail("Stale consume allowed canonical unlink") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalFile(f).path))
        f.clock -= 301
        let reopened = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"))
        let retained = try retirementSource(f, store: reopened, operationID: entry.id)
        let fresh = try await f.expiries(store: reopened).read(wallet: f.wallet(), source: retained)
        _ = try reopened.finishRetirement(retained, expiry: fresh, receipt: nil, now: { f.clock })
        let next = try f.expiryEntry()
        XCTAssertNotEqual(next.id, entry.id)
        XCTAssertThrowsError(try reopened.finishRetirement(source, expiry: expiry, receipt: nil, now: { f.clock }))
        XCTAssertEqual(try reopened.pending(identity: f.identity)?.id, next.id)
    }

    func testKnownPartialRetirementStageRepairRequiresFreshCapAndSameCurrentOperation() async throws {
        for scenario in ["valid", "stale", "different-operation", "ambiguous-decision", "random-pending"] {
            let f = try Fixture(), entry = try f.expiryEntry(phase: .signing)
            let source = try retirementSource(f, store: f.outbox, operationID: entry.id)
            let expiry = try await f.expiries().read(wallet: f.wallet(), source: source)
            let partial = Data("partial snapshot".utf8)
            let snapshot = f.base.appendingPathComponent("outbox/retirement-stage/entry.json")
            let first = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"), retirementFault: {
                if $0 == .snapshotWrite { try partial.write(to: snapshot); throw RetirementCrash.injected }
            })
            do { _ = try first.finishRetirement(source, expiry: expiry, receipt: nil, now: { f.clock }); XCTFail("Partial stage crash absent") } catch { }
            XCTAssertEqual(try Data(contentsOf: snapshot), partial)
            let originalCanonical = try Data(contentsOf: canonicalFile(f))
            let other = try changed(entry) { $0["id"] = UUID().uuidString }
            var boundaryReached = false, diagnosticCaptured = false
            let retry = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"), retirementFault: { point in
                if point == .stageRepairBeforeFreshCheck {
                    boundaryReached = true
                    if scenario == "stale" { f.clock += 301 }
                    if scenario == "different-operation" { try JSONEncoder().encode(other).write(to: self.canonicalFile(f)) }
                }
                if point == .stageDiagnosticSync {
                    let diagnostic = try JSONSerialization.jsonObject(with: Data(contentsOf: f.base.appendingPathComponent("outbox/retirement-repair.json"))) as? [String: Any]
                    XCTAssertEqual(diagnostic?["partialBytes"] as? Int, partial.count)
                    XCTAssertEqual(diagnostic?["partialHash"] as? String, TOSQuantumRetirementCodec.hash(partial).base64EncodedString())
                    diagnosticCaptured = true
                }
            })
            if scenario == "ambiguous-decision" {
                let file = f.base.appendingPathComponent("outbox/retirement-stage/decision.json")
                try Data("{}".utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            var random: URL?
            if scenario == "random-pending" {
                let file = f.base.appendingPathComponent("outbox/" + UUID().uuidString + ".pending")
                try partial.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path); random = file
            }
            if scenario == "valid" {
                let retained = try retirementSource(f, store: retry, operationID: entry.id)
                let fresh = try await f.expiries(store: retry).read(wallet: f.wallet(), source: retained)
                let done = try retry.finishRetirement(retained, expiry: fresh, receipt: nil, now: { f.clock })
                XCTAssertEqual(done.outcome, .expiredUnverified); XCTAssertTrue(boundaryReached); XCTAssertTrue(diagnosticCaptured)
                XCTAssertEqual(done.repair?.partialBytes, partial.count)
                XCTAssertEqual(done.repair?.partialHash, TOSQuantumRetirementCodec.hash(partial))
                XCTAssertNil(try retry.pending(identity: f.identity))
            } else {
                do { _ = try retry.finishRetirement(source, expiry: expiry, receipt: nil, now: { f.clock }); XCTFail("Unsafe stage repair: \(scenario)") } catch { }
                XCTAssertEqual(try Data(contentsOf: snapshot), partial, "Denied repair must retain partial evidence")
                if scenario == "different-operation" {
                    let actual = try JSONDecoder().decode(TOSQuantumOutbox.Entry.self, from: Data(contentsOf: canonicalFile(f)))
                    XCTAssertEqual(actual.id, other.id)
                } else { XCTAssertEqual(try Data(contentsOf: canonicalFile(f)), originalCanonical) }
                if let random { XCTAssertEqual(try Data(contentsOf: random), partial) }
            }
            XCTAssertEqual(f.signs, 0); XCTAssertTrue(f.sends.isEmpty)
        }
    }

    func testRetirementRejectsSymlinkHardlinkAndNonprivateStageWithoutChangingCanonical() async throws {
        for scenario in ["symlink", "hardlink", "directory-mode"] {
            let f = try Fixture(), entry = try f.expiryEntry(phase: .signing)
            let source = try retirementSource(f, store: f.outbox, operationID: entry.id)
            let expiry = try await f.expiries().read(wallet: f.wallet(), source: source)
            let first = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"), retirementFault: {
                if $0 == .workspaceDirectorySync { throw RetirementCrash.injected }
            })
            do { _ = try first.finishRetirement(source, expiry: expiry, receipt: nil, now: { f.clock }); XCTFail("Workspace crash absent") } catch { }
            let workspace = f.base.appendingPathComponent("outbox/retirement-workspace")
            let snapshot = workspace.appendingPathComponent("entry.json")
            let raw = try Data(contentsOf: canonicalFile(f))
            if scenario == "symlink" {
                try FileManager.default.removeItem(at: snapshot)
                try FileManager.default.createSymbolicLink(at: snapshot, withDestinationURL: canonicalFile(f))
            } else if scenario == "hardlink" {
                try FileManager.default.removeItem(at: snapshot)
                XCTAssertEqual(link(canonicalFile(f).path, snapshot.path), 0)
            } else { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workspace.path) }
            let retry = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"))
            XCTAssertThrowsError(try retry.inspectRetirement(identity: f.identity, profile: f.profile))
            XCTAssertThrowsError(try retry.finishRetirement(source, expiry: expiry, receipt: nil, now: { f.clock }))
            XCTAssertEqual(try Data(contentsOf: canonicalFile(f)), raw)
            if scenario == "directory-mode" {
                let attributes = try FileManager.default.attributesOfItem(atPath: workspace.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755, "Existing rejected path must not be chmod'ed")
            }
        }
    }

    func testRetirementHistoryHasBoundedReclamationAndNeverPrunesActiveOrPendingReferences() async throws {
        let f = try Fixture(), entry = try f.expiryEntry(phase: .signing)
        let source = try retirementSource(f, store: f.outbox, operationID: entry.id)
        let expiry = try await f.expiries().read(wallet: f.wallet(), source: source)
        let first = try f.outbox.finishRetirement(source, expiry: expiry, receipt: nil, now: { f.clock })
        let folder = f.base.appendingPathComponent("outbox/retirement-history")
        for _ in 0..<63 {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: TOSQuantumRetirementCodec.encode(first)) as? [String: Any])
            let id = UUID(); var auth = try XCTUnwrap(value["authorization"] as? [String: Any]); auth["operationID"] = id.uuidString
            value["authorization"] = auth
            let record = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            let file = folder.appendingPathComponent(id.uuidString.lowercased() + ".json")
            try record.write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        XCTAssertEqual(try f.outbox.retirementHistory(identity: f.identity, profile: f.profile).count, 64)
        let next = try f.expiryEntry(phase: .signing)
        let nextSource = try retirementSource(f, store: f.outbox, operationID: next.id)
        let fresh = try await f.expiries().read(wallet: f.wallet(), source: nextSource)
        _ = try f.outbox.finishRetirement(nextSource, expiry: fresh, receipt: nil, now: { f.clock })
        let rows = try f.outbox.retirementHistory(identity: f.identity, profile: f.profile)
        XCTAssertEqual(rows.count, 64, "Completed unreferenced reclamation must avoid a permanent 64-operation ceiling")
        XCTAssertTrue(rows.contains { $0.authorization.operationID == next.id })
        let active = try f.expiryEntry()
        // Ordinary local JSON is not proof authority. A deliberately forged local
        // record referencing the active ID must still be excluded from pruning.
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: TOSQuantumRetirementCodec.encode(first)) as? [String: Any])
        var auth = try XCTUnwrap(value["authorization"] as? [String: Any]); auth["operationID"] = active.id.uuidString; value["authorization"] = auth
        _ = try f.outbox.pruneRetirementHistory(maximum: 1)
        let activeRecord = folder.appendingPathComponent(active.id.uuidString.lowercased() + ".json")
        try JSONSerialization.data(withJSONObject: value).write(to: activeRecord)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeRecord.path)
        _ = try f.outbox.pruneRetirementHistory(maximum: 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeRecord.path))
        XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.id, active.id)
        let random = f.base.appendingPathComponent("outbox/" + UUID().uuidString + ".pending")
        try Data("partial".utf8).write(to: random); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: random.path)
        XCTAssertThrowsError(try f.outbox.pruneRetirementHistory(maximum: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeRecord.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: random.path))
    }

    func testPublicRetirementCoordinatorPreservesSignedAndUnknownPaymentBOCAcrossSnapshotRestart() async throws {
        for phase in [TOSQuantumOutbox.Phase.signed, .unknown] {
            let f = try Fixture(), entry = try f.expiryEntry(phase: phase, withPaymentIntent: true)
            let boc = try XCTUnwrap(entry.signedBOC), signature = try XCTUnwrap(entry.signature)
            let crashing = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"), retirementFault: {
                if $0 == .canonicalUnlink { throw RetirementCrash.injected }
            })
            let first = try TOSQuantumRetirementCoordinator(outbox: crashing, baseDirectory: f.base,
                expiry: f.expiries(store: crashing), outcomes: f.outcomes(store: crashing), now: { f.clock })
            do { _ = try await first.review(wallet: f.wallet(), operationID: UUID()); XCTFail("Different operation reviewed") } catch { }
            let review = try await first.review(wallet: f.wallet(), operationID: entry.id)
            XCTAssertEqual(review.entry.paymentIntent, entry.paymentIntent)
            XCTAssertEqual(review.entry.signature, signature); XCTAssertEqual(review.entry.signedBOC, boc)
            XCTAssertEqual(review.outcome, .expiredUnverified)
            do { _ = try await first.complete(review); XCTFail("Canonical unlink interruption absent") } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalFile(f).path))
            let reopened = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"))
            let service = try TOSQuantumRetirementCoordinator(outbox: reopened, baseDirectory: f.base,
                expiry: f.expiries(store: reopened), outcomes: f.outcomes(store: reopened), now: { f.clock })
            let state = try await service.inspect(wallet: f.wallet())
            guard case .authorization(let retained, let recovering) = state else { return XCTFail("Full snapshot source lost") }
            XCTAssertTrue(recovering); XCTAssertEqual(retained.phase, phase); XCTAssertEqual(retained.signedBOC, boc)
            let recoveredReview = try await service.review(wallet: f.wallet(), operationID: entry.id)
            let completed = try await service.complete(recoveredReview)
            XCTAssertEqual(completed.outcome, .expiredUnverified); XCTAssertNil(completed.transaction)
            XCTAssertEqual(completed.authorization.messageBytesHash, TOSQuantumRetirementCodec.hash(boc))
            XCTAssertEqual(completed.authorization.intent?.amount, String(try XCTUnwrap(entry.paymentIntent).amount))
            let history = try await service.localHistory(wallet: f.wallet())
            XCTAssertEqual(history.count, 1); XCTAssertEqual(history.first?.publication, .releaseCompleted)
            XCTAssertNil(try reopened.pending(identity: f.identity))
            do { _ = try await service.review(wallet: f.wallet(), operationID: entry.id); XCTFail("Completed local history recreated a review capability") } catch { }
            let next = try f.expiryEntry(phase: .signed, withPaymentIntent: true)
            do { _ = try await service.complete(recoveredReview); XCTFail("Old review touched a new operation") } catch { }
            XCTAssertEqual(try reopened.pending(identity: f.identity)?.id, next.id)
            XCTAssertEqual(f.signs, 0); XCTAssertTrue(f.sends.isEmpty)
        }
    }

    func testCancellationAfterDurableCompletionBeforeCallbackRecoversCompletedAndCannotTouchNewSlot() async throws {
        let f = try Fixture(), entry = try f.expiryEntry(phase: .unknown, withPaymentIntent: true)
        let entered = expectation(description: "Completed record and both directories are durable before callback")
        let resume = DispatchSemaphore(value: 0)
        var hit = false
        let stopped = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"), retirementFault: { point in
            if point == .completedWorkspaceDirectorySync, !hit {
                hit = true; entered.fulfill()
                guard resume.wait(timeout: .now() + 20) == .success else { throw RetirementCrash.injected }
            }
        })
        let service = try TOSQuantumRetirementCoordinator(outbox: stopped, baseDirectory: f.base,
            expiry: f.expiries(store: stopped), outcomes: f.outcomes(store: stopped), now: { f.clock })
        let review = try await service.review(wallet: f.wallet(), operationID: entry.id)
        let completing = Task { try await service.complete(review) }
        await fulfillment(of: [entered], timeout: 10)
        completing.cancel(); resume.signal()
        do { _ = try await completing.value; XCTFail("Cancelled completion callback returned success") }
        catch { XCTAssertTrue(error is CancellationError, "The transaction must finish, then observe cancellation") }
        XCTAssertTrue(hit)
        let reopened = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"))
        let restarted = try TOSQuantumRetirementCoordinator(outbox: reopened, baseDirectory: f.base,
            expiry: f.expiries(store: reopened), outcomes: f.outcomes(store: reopened), now: { f.clock })
        let state = try await restarted.inspect(wallet: f.wallet())
        switch state {
        case .none: break // Completed workspace already cleaned; consult bounded local history.
        case .completed(let summary): XCTAssertEqual(summary.authorization.operationID, entry.id)
        case .authorization: XCTFail("Cancelled callback resurrected the old canonical")
        }
        let history = try await restarted.localHistory(wallet: f.wallet())
        XCTAssertEqual(history.count, 1); XCTAssertEqual(history.first?.publication, .releaseCompleted)
        XCTAssertEqual(history.first?.authorization.operationID, entry.id)
        XCTAssertEqual(history.first?.authorization.messageBytesHash,
                       TOSQuantumRetirementCodec.hash(try XCTUnwrap(entry.signedBOC)))
        XCTAssertNil(try reopened.pending(identity: f.identity))
        let next = try f.expiryEntry(phase: .signed, withPaymentIntent: true)
        let newBytes = try Data(contentsOf: canonicalFile(f))
        do { _ = try await restarted.complete(review); XCTFail("Cancelled old review touched the next payment") } catch { }
        XCTAssertEqual(try Data(contentsOf: canonicalFile(f)), newBytes)
        XCTAssertEqual(try reopened.pending(identity: f.identity)?.id, next.id)
        XCTAssertEqual(f.signs, 0); XCTAssertTrue(f.sends.isEmpty)
    }

    func testSentAndIncludedMismatchLocalSummaryBranchesAreDataNotCapabilities() async throws {
        let f = try Fixture(), entry = try f.expiryEntry(phase: .signed, withPaymentIntent: true)
        let source = try retirementSource(f, store: f.outbox, operationID: entry.id)
        let expiry = try await f.expiries().read(wallet: f.wallet(), source: source)
        let completed = try f.outbox.finishRetirement(source, expiry: expiry, receipt: nil, now: { f.clock })
        for outcome in [TOSQuantumRetirementSummary.Outcome.senderSent, .includedWithoutExactTransfer] {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: TOSQuantumRetirementCodec.encode(completed)) as? [String: Any])
            value["outcome"] = outcome.rawValue
            value["transaction"] = ["hash":Data(repeating: 0x42, count: 32).base64EncodedString(), "logicalTime":"1", "timestamp":expiry.provenShardTime]
            let local = try JSONDecoder().decode(TOSQuantumRetirementSummary.self, from: JSONSerialization.data(withJSONObject: value))
            try local.validate(); XCTAssertEqual(local.completed().outcome, outcome)
            XCTAssertEqual(local.authorization.messageBytesHash, TOSQuantumRetirementCodec.hash(try XCTUnwrap(entry.signedBOC)))
            // This only exercises public local-record format. It deliberately
            // does not construct Receipt/Expiry/Review or authorize an unlink.
            let next = try f.expiryEntry()
            XCTAssertThrowsError(try f.outbox.finishRetirement(source, expiry: expiry, receipt: nil, now: { f.clock }))
            XCTAssertEqual(try f.outbox.pending(identity: f.identity)?.id, next.id)
            try f.outbox.cancelUnsigned(next)
        }
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
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        var original = stat()
        guard fstat(descriptor, &original) == 0, original.st_mode & S_IFMT == S_IFDIR,
              original.st_uid == geteuid(), original.st_mode & 0o7777 == 0o700,
              original.st_flags & UInt32(UF_IMMUTABLE) == 0 else { throw TOSPQError.invalidInput }
        func systemFailure(_ operation: String, _ code: Int32) -> NSError {
            NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: operation + "; errno=\(code)"])
        }
        func securityState() throws -> (flags: UInt32, acl: Data?) {
            guard let security = filesec_init() else { throw systemFailure("filesec_init", errno) }
            defer { filesec_free(security) }
            var current = stat()
            guard lstatx_np(directory.path, &current, security) == 0 else { throw systemFailure("lstatx_np", errno) }
            guard current.st_dev == original.st_dev, current.st_ino == original.st_ino,
                  current.st_mode & S_IFMT == S_IFDIR, current.st_uid == original.st_uid,
                  current.st_mode & 0o7777 == 0o700 else { throw TOSPQError.keyBinding }
            var present: Int32 = 0
            guard filesec_query_property(security, FILESEC_ACL, &present) == 0 else {
                throw systemFailure("filesec_query_property(FILESEC_ACL)", errno)
            }
            if present == 0 { return (current.st_flags, nil) }
            var captured: acl_t?
            guard filesec_get_property(security, FILESEC_ACL, &captured) == 0, let captured else {
                throw systemFailure("filesec_get_property(FILESEC_ACL)", errno)
            }
            defer { acl_free(UnsafeMutableRawPointer(captured)) }
            let size = acl_size(captured)
            guard size > 0, size <= 64 * 1024 else { throw TOSPQError.invalidInput }
            var bytes = Data(count: size)
            let copied = bytes.withUnsafeMutableBytes { acl_copy_ext($0.baseAddress, captured, size) }
            guard copied == size else { throw systemFailure("acl_copy_ext", errno) }
            return (current.st_flags, bytes)
        }
        let originalACL = try securityState().acl
        let probe = directory.appendingPathComponent("immutable-create-probe-" + UUID().uuidString)
        func restoreOriginalSecurity() throws {
            guard fchflags(descriptor, original.st_flags) == 0 else { throw systemFailure("Restore original flags", errno) }
            guard fchmod(descriptor, original.st_mode & 0o7777) == 0 else { throw systemFailure("Restore original mode", errno) }
            let restored = try securityState()
            guard restored.flags == original.st_flags, restored.acl == originalACL else { throw TOSPQError.keyBinding }
            // An unexpectedly successful probe must not survive a failed test.
            if unlink(probe.path) != 0, errno != ENOENT { throw systemFailure("Remove unexpected probe", errno) }
        }
        defer { XCTAssertNoThrow(try restoreOriginalSecurity(), "Restore exact flags, inode, owner, mode and ACL state") }
        let immutableFlags = original.st_flags | UInt32(UF_IMMUTABLE)
        func makeImmutable() throws {
            guard fchflags(descriptor, immutableFlags) == 0 else { throw systemFailure("Set owner UF_IMMUTABLE", errno) }
            let installed = try securityState()
            guard installed.flags == immutableFlags, installed.acl == originalACL else { throw TOSPQError.keyBinding }
        }
        // Prove the owner can both set and clear this flag before starting a
        // broadcast. No mode or ACL changes manufacture the system error.
        try makeImmutable(); try restoreOriginalSecurity()
        let entered = expectation(description: "Durable broadcast entered"), resume = DispatchSemaphore(value: 0)
        enum RelayFailure: Error { case responseLost }
        f.onBroadcast = { entered.fulfill(); _ = resume.wait(timeout: .now() + 20); throw RelayFailure.responseLost }
        let sending = Task { try await coordinator.submit(quote) }
        await fulfillment(of: [entered], timeout: 10)
        do {
            try makeImmutable()
            errno = 0
            let probeFD = open(probe.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            let failure = errno
            if probeFD >= 0 { close(probeFD) }
            guard probeFD == -1, failure == EPERM else {
                XCTFail("UF_IMMUTABLE must produce actual EPERM, got fd=\(probeFD), errno=\(failure)")
                throw TOSPQError.invalidInput
            }
            _ = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let retained = try XCTUnwrap(f.outbox.pending(identity: f.identity))
            XCTAssertEqual(retained.phase, .submitting); XCTAssertEqual(retained.signedBOC, f.sends.first)
            let diagnostic = XCTAttachment(string: "owner=\(original.st_uid); originalFlags=\(original.st_flags); installedFlags=\(immutableFlags); mode0700/same inode/ACL unchanged; actual O_CREAT|O_EXCL errno=EPERM; existing lock/list/read succeeded")
            diagnostic.name = "real-cancelled-write-permission-failure"; diagnostic.lifetime = .keepAlways; add(diagnostic)
        } catch {
            sending.cancel(); resume.signal(); _ = try? await sending.value
            throw error
        }
        sending.cancel(); resume.signal()
        do { try await sending.value; XCTFail("Uncertain storage returned success") }
        catch {
            let failure = error as NSError
            XCTAssertEqual(failure.domain, NSCocoaErrorDomain, "Cancellation masked the actual durable-write error")
            XCTAssertEqual(failure.code, NSFileWriteNoPermissionError)
        }
        try restoreOriginalSecurity()
        let restoredDiagnostic = XCTAttachment(string: "Exact original st_flags restored; same dev/inode/owner/mode0700 and extended ACL bytes/absence verified")
        restoredDiagnostic.name = "write-failure-fixture-restored"; restoredDiagnostic.lifetime = .keepAlways; add(restoredDiagnostic)
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
