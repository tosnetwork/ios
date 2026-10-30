import XCTest
import BigInt
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSQuantumAccountReaderTests: XCTestCase {
    private final class Transcript {
        var replies: [Data]
        var calls = 0
        init(_ replies: [Data]) { self.replies = replies }
        func query(_ request: Data, _ capacity: Int) throws -> Data {
            guard calls < replies.count, replies[calls].count <= capacity else { throw TOSPQError.invalidInput }
            defer { calls += 1 }; return replies[calls]
        }
    }
    private final class Fixture {
        let base: URL, assets: URL, id = UUID(), identity: TOSQuantumSelfPayIdentity
        let profile: TOSQuantumNetworkProfile, now: Int64
        let role: String
        init(_ role: String = "active", globalID: Int32 = 1) throws {
            self.role = role
            let resources = try XCTUnwrap(Bundle.module.url(forResource: "quantum-self-pay-live", withExtension: nil))
            assets = resources
            func data(_ n: String) throws -> Data { try Data(contentsOf: resources.appendingPathComponent(n)) }
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data("manifest.json")) as? [String: Any])
            now = try XCTUnwrap(manifest["controlled_now"] as? NSNumber).int64Value
            let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data("public-self-pay-accounts.json")) as? [String: Any])
            let records = try XCTUnwrap(fixture["accounts"] as? [String: [String: Any]])
            let encoded = try XCTUnwrap(records[role]?["identity_boc"] as? String)
            let original = try TOSQuantumSelfPayIdentity(boc: XCTUnwrap(Data(base64Encoded: encoded)))
            if globalID == 1 { identity = original }
            else {
                let a = original.wallet.initialAuthority
                identity = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority:
                    TOSQuantumSelfPayAuthority(globalID: globalID, namespace: a.namespace, primaryKey: a.primaryKey, rescueKey: a.rescueKey)))
            }
            let anchor = try XCTUnwrap(JSONSerialization.jsonObject(with: data("anchor.json")) as? [String: Any])
            profile = try TOSQuantumNetworkProfile(globalID: globalID,
                rootHash: XCTUnwrap(anchor["root_hash"] as? String), fileHash: XCTUnwrap(anchor["file_hash"] as? String))
            base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            if identity.wallet.walletID == 0 {
                try TOSQuantumCreationRecord(id: id, profile: profile, identity: identity).save(baseDirectory: base)
            }
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        func data(_ name: String) throws -> Data { try Data(contentsOf: assets.appendingPathComponent(name)) }
        func transcript(account: Bool) throws -> Transcript {
            var names = ["policy/material/masterchain-info.tl", "policy/material/chain-0000.tl", "policy/material/config.tl"]
            if account { names += [role + "/material/chain-0000.tl", role + "/material/account.tl"] }
            return try Transcript(names.map(data))
        }
        func enroll() throws {
            let t = try transcript(account: false)
            let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: profile.anchor(), baseDirectory: base)
            _ = try session.enrollBound(request: data("policy/request.json"), now: now, transport: t.query)
            XCTAssertEqual(t.calls, 3)
        }
        func wallet() -> Wallet {
            Wallet(id: id.uuidString, identity: WalletIdentity(network: .mainnet, kind: .Quantum(identity), networkGlobalId: profile.globalID),
                metaData: WalletMetaData(label: "Public fixture", tintColor: .defaultColor, icon: .icon(.wallet)),
                setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
        }
    }

    func testRecordedNativeReadsRetainAllStatusesAndOriginalEnrollment() async throws {
        for role in ["active", "prefunded", "absent"] {
            let f = try Fixture(role); try f.enroll(); let t = try f.transcript(account: true)
            let reader = TOSQuantumAccountReader(baseDirectory: f.base, transport: { t.query }, now: { f.now })
            let result: TOSQuantumSelfPayAccount.Snapshot
            if role == "active" { result = try await reader.read(wallet: f.wallet()) }
            else { result = try reader.readEnrolled(id: f.id, identity: f.identity, profile: f.profile) }
            XCTAssertEqual(t.calls, 5)
            switch (role, result.status) {
            case ("active", .active): XCTAssertEqual(result.balance, 1_000_000_000_000_000)
            case ("prefunded", .uninitialized): XCTAssertEqual(result.balance, 10_000_000_000)
            case ("absent", .absent): XCTAssertEqual(result.balance, 0)
            default: XCTFail("Wrong authenticated status")
            }
        }
    }

    func testMissingCheckpointAndWrongBirthDoNotQueryOrReenroll() throws {
        let f = try Fixture(), t = try f.transcript(account: true)
        let reader = TOSQuantumAccountReader(baseDirectory: f.base, transport: { t.query }, now: { f.now })
        XCTAssertThrowsError(try reader.readStored(id: f.id, identity: f.identity))
        XCTAssertEqual(t.calls, 0)
        let a = f.identity.wallet.initialAuthority
        let wrong = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority:
            TOSQuantumSelfPayAuthority(globalID: 1, namespace: a.namespace, primaryKey: Data(repeating: 7, count: 1312), rescueKey: a.rescueKey)))
        XCTAssertThrowsError(try reader.readStored(id: f.id, identity: wrong)) { error in
            guard case TOSPQError.keyBinding = error else { return XCTFail("Wrong refusal: \(error)") }
        }
        XCTAssertEqual(t.calls, 0)
        XCTAssertEqual(try TOSQuantumCreationRecord.load(id: f.id, baseDirectory: f.base).identity, f.identity)
    }

    func testWrongProvenNetworkIsRefusedBeforeAccountQuery() throws {
        let f = try Fixture(globalID: 2); try f.enroll(); let t = try f.transcript(account: true)
        let reader = TOSQuantumAccountReader(baseDirectory: f.base, transport: { t.query }, now: { f.now })
        XCTAssertThrowsError(try reader.readStored(id: f.id, identity: f.identity)) { error in
            guard case TOSPQError.keyBinding = error else { return XCTFail("Wrong refusal: \(error)") }
        }
        XCTAssertEqual(t.calls, 3)
    }

    func testStaleOrCorruptProofNeverProducesASnapshot() throws {
        for corrupt in [false, true] {
            let f = try Fixture(); try f.enroll(); let t = try f.transcript(account: true)
            if corrupt { t.replies[2][20] ^= 1 }
            let reader = TOSQuantumAccountReader(baseDirectory: f.base, transport: { t.query }, now: { f.now + (corrupt ? 0 : 301) })
            XCTAssertThrowsError(try reader.readStored(id: f.id, identity: f.identity)) { error in
                guard case TOSPQError.invalidInput = error else { return XCTFail("Wrong proof error: \(error)") }
            }
            XCTAssertEqual(t.calls, 3)
        }
    }

    func testPublicReadRefusesFullCapacityBeforeOpeningTransport() async throws {
        let f = try Fixture(), gate = TOSQuantumAccountReader.Permits(), one = UUID(), two = UUID()
        try gate.enter(one); try gate.enter(two)
        var opened = false
        let reader = TOSQuantumAccountReader(baseDirectory: f.base, transport: { opened = true; throw TOSPQError.invalidInput }, permits: gate)
        do { _ = try await reader.read(wallet: f.wallet()); XCTFail("Read exceeded two active wallets") }
        catch TOSQuantumAccountReader.Error.busy {}
        XCTAssertFalse(opened)
        gate.leave(one); try gate.enter(f.id)
        XCTAssertThrowsError(try gate.enter(f.id))
        gate.leave(f.id); gate.leave(two)
        try gate.enter(one); gate.leave(one)
    }

    func testObservationRetainsProofHeadAndRechecksItsFreshness() async throws {
        let f = try Fixture(); try f.enroll(); let t = try f.transcript(account: true)
        let reader = TOSQuantumAccountReader(baseDirectory: f.base, transport: { t.query }, now: { f.now })
        let value = try await reader.observe(wallet: f.wallet(), configIndices: [8, 19, 48])
        XCTAssertEqual(value.id, f.id); XCTAssertEqual(value.identity, f.identity)
        XCTAssertEqual(value.profile, f.profile); XCTAssertEqual(t.calls, 5)
        try value.requireFresh(now: f.now)
        XCTAssertThrowsError(try value.requireFresh(now: f.now + 301))
        let head = try value.proof.provenTransactionHead(expectedAddress: f.identity.address.toRaw())
        XCTAssertEqual(head.logicalTime, 0); XCTAssertEqual(head.hash, Data(repeating: 0, count: 32))
        XCTAssertThrowsError(try value.proof.provenTransactionHead(expectedAddress: "0:" + String(repeating: "0", count: 64)))
    }

    func testPrimaryPaymentPreparesFromAuthenticatedAccountAndJournalsMatchingIntent() async throws {
        let f = try Fixture(); try f.enroll(); let t = try f.transcript(account: true)
        let reader = TOSQuantumAccountReader(baseDirectory: f.base, transport: { t.query }, now: { f.now })
        let service = TOSQuantumPaymentService(reader: reader, now: { f.now })
        let recipient = Address(workchain: 0, hash: Data(repeating: 0x42, count: 32))
        let intent = try TOSQuantumPaymentIntent(recipient: recipient, amount: 1_000_000_000, bounce: false, comment: "付款🌸")
        let payment = try await service.prepare(wallet: f.wallet(), intent: intent, ttl: 60)
        XCTAssertEqual(t.calls, 5); XCTAssertFalse(payment.requiresDeployment)
        XCTAssertEqual(payment.identity, f.identity); XCTAssertEqual(payment.profile, f.profile)
        XCTAssertEqual(payment.observedBalance, 1_000_000_000_000_000)
        XCTAssertEqual(payment.expiresAt, UInt32(f.now) + 60); XCTAssertEqual(payment.request.role, .primary)
        try intent.requireBound(request: payment.request.request, role: .primary)
        let outbox = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"))
        let entry = try outbox.reserve(payment: payment, now: f.now)
        XCTAssertEqual(entry.paymentIntent, intent)
        XCTAssertEqual(try outbox.pending(identity: f.identity)?.paymentIntent, intent)
        XCTAssertEqual(try outbox.pending(identity: f.identity)?.requestHash, payment.request.digest)
        try outbox.cancelUnsigned(entry)
        for other in [
            try TOSQuantumPaymentIntent(recipient: recipient, amount: intent.amount + 1, bounce: false, comment: intent.comment),
            try TOSQuantumPaymentIntent(recipient: recipient, amount: intent.amount, bounce: true, comment: intent.comment),
            try TOSQuantumPaymentIntent(recipient: recipient, amount: intent.amount, bounce: false, comment: "different"),
            try TOSQuantumPaymentIntent(recipient: f.identity.address, amount: intent.amount, bounce: false, comment: intent.comment)
        ] {
            XCTAssertThrowsError(try outbox.reserve(identity: payment.identity, profile: payment.profile,
                request: payment.request, deploy: false, paymentIntent: other)) { error in
                guard case TOSPQError.keyBinding = error else { return XCTFail("Wrong intent refusal: \(error)") }
            }
            XCTAssertNil(try outbox.pending(identity: f.identity))
        }
    }

    func testExpiredPaymentCannotReserveWhileItsAccountProofIsStillYoung() async throws {
        let f = try Fixture(); try f.enroll(); let t = try f.transcript(account: true)
        let reader = TOSQuantumAccountReader(baseDirectory: f.base, transport: { t.query }, now: { f.now })
        let intent = try TOSQuantumPaymentIntent(recipient: f.identity.address, amount: 1, bounce: false)
        let payment = try await TOSQuantumPaymentService(reader: reader, now: { f.now })
            .prepare(wallet: f.wallet(), intent: intent, ttl: 60)
        XCTAssertNoThrow(try payment.requireFresh(now: f.now + 59))
        let outbox = try TOSQuantumOutbox(baseDirectory: f.base.appendingPathComponent("outbox"))
        XCTAssertThrowsError(try outbox.reserve(payment: payment, now: f.now + 60)) { error in
            guard case TOSQuantumPreparedPayment.Error.expired = error else { return XCTFail("Wrong expiry refusal: \(error)") }
        }
        XCTAssertNil(try outbox.pending(identity: f.identity))
        XCTAssertThrowsError(try payment.requireFresh(now: f.now + 301))
    }

    func testPaymentRefusesMismatchedWalletNetworkBeforeOpeningRelay() async throws {
        let f = try Fixture(); try f.enroll(); let t = try f.transcript(account: true)
        let reader = TOSQuantumAccountReader(baseDirectory: f.base, transport: { t.query }, now: { f.now })
        let original = f.wallet()
        let wrong = Wallet(id: original.id,
            identity: WalletIdentity(network: .mainnet, kind: .Quantum(f.identity), networkGlobalId: 2),
            metaData: original.metaData, setupSettings: original.setupSettings, batterySettings: original.batterySettings)
        let intent = try TOSQuantumPaymentIntent(recipient: f.identity.address, amount: 1, bounce: false)
        do {
            _ = try await TOSQuantumPaymentService(reader: reader, now: { f.now }).prepare(wallet: wrong, intent: intent)
            XCTFail("Prepared a payment for inconsistent UI network identity")
        } catch TOSPQError.keyBinding {}
        XCTAssertEqual(t.calls, 0)
    }

    func testPrefundedPaymentRetainsBirthDeploymentAndAbsentAccountRequiresFunding() throws {
        for role in ["prefunded", "absent"] {
            let f = try Fixture(role); try f.enroll(); let t = try f.transcript(account: true)
            let reader = TOSQuantumAccountReader(baseDirectory: f.base, transport: { t.query }, now: { f.now })
            let observation = try reader.observeEnrolled(id: f.id, identity: f.identity, profile: f.profile,
                                                        configIndices: [8, 19, 48])
            let intent = try TOSQuantumPaymentIntent(recipient: f.identity.address, amount: 1_000_000_000, bounce: false)
            if role == "prefunded" {
                let payment = try TOSQuantumPreparedPayment(observation: observation, intent: intent, now: f.now, ttl: 60)
                XCTAssertTrue(payment.requiresDeployment); XCTAssertEqual(payment.identity, f.identity)
                XCTAssertEqual(payment.request.wallet, f.identity.address)
                XCTAssertEqual(payment.request.signingPublicKey, f.identity.wallet.initialAuthority.primaryKey)
            } else {
                XCTAssertThrowsError(try TOSQuantumPreparedPayment(observation: observation, intent: intent, now: f.now, ttl: 60)) { error in
                    guard case TOSQuantumPreparedPayment.Error.insufficientValue = error else { return XCTFail("Wrong funding refusal: \(error)") }
                }
            }
            XCTAssertEqual(t.calls, 5)
        }
    }

    func testDuplicateOrUnboundedConfigurationRequestsDoNotOpenRelay() async throws {
        let f = try Fixture()
        var opened = false
        let reader = TOSQuantumAccountReader(baseDirectory: f.base, transport: { opened = true; throw TOSPQError.invalidInput })
        for indices in [[], [19, 19], [19, 999], Array(0..<100)] {
            do { _ = try await reader.observe(wallet: f.wallet(), configIndices: indices); XCTFail("Unbounded config request accepted") }
            catch TOSPQError.invalidInput { }
        }
        XCTAssertFalse(opened)
    }

    func testLiveNativeReaderUsesOriginalEnrollment() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["TOS_QUANTUM_ROOT_HASH"], !root.isEmpty,
              let file = env["TOS_QUANTUM_FILE_HASH"], !file.isEmpty,
              env["TOS_QUANTUM_GLOBAL_ID"] == "1",
              let endpoint = env["TOS_UI_RPC_URL"], let url = URL(string: endpoint + "/jsonRPC") else {
            throw XCTSkip("Requires isolated public self-pay native chain and independently supplied anchor")
        }
        let f = try Fixture()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let profile = try TOSQuantumNetworkProfile(globalID: 1, rootHash: root, fileHash: file)
        try TOSQuantumCreationRecord(id: f.id, profile: profile, identity: f.identity).save(baseDirectory: base)
        let anchor = try profile.anchor(), id = f.id
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let relay = try TOSQuantumProofHTTPTransport(endpoint: url)
                    let transport: TOSQuantumProofBridge.Transport = { try relay.query($0, maximumBytes: $1) }
                    let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: anchor, baseDirectory: base)
                    _ = try session.enrollBound(request: TOSQuantumSelfPayNetwork.request(maximumAge: 300),
                        now: Int64(Date().timeIntervalSince1970), transport: transport)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        let relay = try TOSQuantumProofHTTPTransport(endpoint: url)
        let transport: TOSQuantumProofBridge.Transport = { try relay.query($0, maximumBytes: $1) }
        let result = try await TOSQuantumAccountReader(baseDirectory: base, transport: { transport }).read(wallet: f.wallet())
        guard case .active = result.status else { return XCTFail("Expected public genesis active account") }
        XCTAssertEqual(result.balance, 1_000_000_000_000_000)
    }

    func testLiveHistoryUsesProvenHeadRawCellsAndBoundPagination() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["TOS_QUANTUM_ROOT_HASH"], !root.isEmpty,
              let file = env["TOS_QUANTUM_FILE_HASH"], !file.isEmpty,
              env["TOS_QUANTUM_GLOBAL_ID"] == "1",
              let expectedString = env["TOS_QUANTUM_EXTERNAL_HASH"], expectedString.count == 64,
              let expectedHash = Data(hex: expectedString), expectedHash.count == 32,
              let endpoint = env["TOS_UI_RPC_URL"], let url = URL(string: endpoint + "/jsonRPC") else {
            throw XCTSkip("Requires a public test chain with two signed transfers and an independently supplied message hash")
        }
        let f = try Fixture(), base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let profile = try TOSQuantumNetworkProfile(globalID: 1, rootHash: root, fileHash: file)
        try TOSQuantumCreationRecord(id: f.id, profile: profile, identity: f.identity).save(baseDirectory: base)
        let anchor = try profile.anchor(), id = f.id
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let relay = try TOSQuantumProofHTTPTransport(endpoint: url)
                    let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: anchor, baseDirectory: base)
                    _ = try session.enrollBound(request: TOSQuantumSelfPayNetwork.request(maximumAge: 300),
                        now: Int64(Date().timeIntervalSince1970), transport: { try relay.query($0, maximumBytes: $1) })
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        let relay = try TOSQuantumProofHTTPTransport(endpoint: url)
        let accounts = TOSQuantumAccountReader(baseDirectory: base, transport: { { try relay.query($0, maximumBytes: $1) } })
        let previousEndpoint = TOSRPCSettings.customEndpoint
        try TOSRPCSettings.setCustomEndpoint(endpoint)
        defer {
            if let previousEndpoint { _ = try? TOSRPCSettings.setCustomEndpoint(previousEndpoint) }
            else { TOSRPCSettings.reset() }
        }
        let history = TOSQuantumHistoryReader(accounts: accounts)
        let first = try await history.read(wallet: f.wallet(), limit: 1)
        XCTAssertEqual(first.transactions.count, 1); XCTAssertTrue(first.hasMore)
        let cursor = try XCTUnwrap(first.next)
        let second = try await history.read(wallet: f.wallet(), cursor: cursor, limit: 1)
        XCTAssertEqual(second.transactions.count, 1); XCTAssertFalse(second.hasMore)
        XCTAssertEqual(first.checkpointTime, second.checkpointTime)
        let firstTransaction = try XCTUnwrap(first.transactions.first)
        let secondTransaction = try XCTUnwrap(second.transactions.first)
        XCTAssertEqual(firstTransaction.previousHash, secondTransaction.hash)
        let recipientFixture = try XCTUnwrap(JSONSerialization.jsonObject(with: f.data("public-self-pay-accounts.json")) as? [String: Any])
        let records = try XCTUnwrap(recipientFixture["accounts"] as? [String: [String: Any]])
        let recipient = try TOSQuantumSelfPayIdentity(boc: XCTUnwrap(Data(base64Encoded:
            XCTUnwrap(records["absent"]?["identity_boc"] as? String))))
        let tx = firstTransaction
        XCTAssertTrue(tx.matchesOutgoingTransfer(externalHash: expectedHash, sender: f.identity.address, recipient: recipient.address,
                                       amount: 10_000_000_000, bodyHash: try Builder().endCell().hash()))
        XCTAssertGreaterThan(tx.timestamp, 0)
        XCTAssertNotEqual(tx.fees, 999_999_999_999)
        func mode(_ value: String) async throws {
            var request = URLRequest(url: try XCTUnwrap(URL(string: endpoint + "/__history_mode")))
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": value])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (bytes, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200); XCTAssertLessThan(bytes.count, 128)
        }
        try await mode("corrupt")
        do { _ = try await history.read(wallet: f.wallet()); XCTFail("Changed transaction fee bytes bypassed the proven transaction hash") }
        catch TOSPQError.invalidInput { }
        try await mode("normal")
        let restored = try await history.read(wallet: f.wallet())
        XCTAssertEqual(restored.transactions.count, 2); XCTAssertFalse(restored.hasMore)
        XCTAssertEqual(restored.transactions.first?.hash, firstTransaction.hash)
    }
}
