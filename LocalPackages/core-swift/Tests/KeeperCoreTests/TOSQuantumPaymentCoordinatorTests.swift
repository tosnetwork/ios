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
