import XCTest
import Foundation
import BigInt
import TonSwift
import CoreComponents
@testable import KeeperCore

/// Actual private receipt -> public retirement result branches. Uses only the
/// already public fixture seed, never App custody. No synthetic receipt issuer.
final class TOSQuantumRetirementLiveTests: XCTestCase {
    private func background<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func testLiveSenderSentAndIncludedMismatchRetireOnlyAfterRealShardExpiry() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TOS_QUANTUM_RETIREMENT_LIVE"] == "1", env["TOS_QUANTUM_GLOBAL_ID"] == "1",
              let root = env["TOS_QUANTUM_ROOT_HASH"], !root.isEmpty,
              let file = env["TOS_QUANTUM_FILE_HASH"], !file.isEmpty,
              let endpoint = env["TOS_UI_RPC_URL"], let url = URL(string: endpoint + "/jsonRPC") else {
            throw XCTSkip("Requires the isolated public-fixture chain and explicit R03-B live opt-in; no App custody claim")
        }
        let resources = try XCTUnwrap(Bundle.module.url(forResource: "quantum-self-pay-live", withExtension: nil))
        let registry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("public-self-pay-accounts.json"))) as? [String: Any])
        let rows = try XCTUnwrap(registry["accounts"] as? [String: [String: Any]])
        func identity(_ name: String) throws -> TOSQuantumSelfPayIdentity {
            try TOSQuantumSelfPayIdentity(boc: XCTUnwrap(Data(base64Encoded: XCTUnwrap(rows[name]?["identity_boc"] as? String))))
        }
        let sender = try identity("active"), recipient = try identity("absent")
        let profile = try TOSQuantumNetworkProfile(globalID: 1, rootHash: root, fileHash: file)
        let rpc = try TOSQuantumRPCTransport(endpoint: url)
        for mismatch in [false, true] {
            let label = mismatch ? "included-mismatch" : "sender-sent"
            let id = UUID(), base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: base) }
            try TOSQuantumCreationRecord(id: id, profile: profile, identity: sender).save(baseDirectory: base)
            let store = try TOSQuantumOutbox(baseDirectory: base.appendingPathComponent("outbox"))
            let wallet = Wallet(id: id.uuidString, identity: WalletIdentity(network: .mainnet, kind: .Quantum(sender), networkGlobalId: 1),
                metaData: WalletMetaData(label: "Public retirement fixture", tintColor: .defaultColor, icon: .icon(.wallet)),
                setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
            let lock = NSLock(); var traces = [(Data, Data)](), traceBytes = 0, transactions = [Data](), transactionBytes = 0
            func attach(_ data: Data, _ name: String) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.data")
                attachment.name = label + "-" + name; attachment.lifetime = .keepAlways; add(attachment)
            }
            defer {
                for (index, pair) in traces.enumerated() { attach(pair.0, "query-\(index).tl"); attach(pair.1, "response-\(index).tl") }
                for (index, bytes) in transactions.enumerated() { attach(bytes, "transaction-\(index).boc") }
            }
            let relay = try TOSQuantumProofHTTPTransport(endpoint: url)
            let proof: TOSQuantumProofBridge.Transport = { query, capacity in
                let response = try relay.query(query, maximumBytes: capacity)
                try lock.withLock {
                    guard traces.count < 1024, traceBytes + query.count + response.count <= 16 * 1024 * 1024 else { throw TOSPQError.invalidInput }
                    traces.append((query, response)); traceBytes += query.count + response.count
                }
                return response
            }
            try await background {
                let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: profile.anchor(), baseDirectory: base)
                _ = try session.enrollBound(request: TOSQuantumSelfPayNetwork.request(maximumAge: 300),
                    now: Int64(Date().timeIntervalSince1970), transport: proof)
            }
            let accounts = TOSQuantumAccountReader(baseDirectory: base, transport: { proof })
            let intent = try TOSQuantumPaymentIntent(recipient: recipient.address,
                amount: mismatch ? BigUInt(1) << 119 : 1_000_000, bounce: false, comment: "R03 B " + label)
            if !mismatch {
                let prepared = try await TOSQuantumPaymentService(reader: accounts, now: { Int64(Date().timeIntervalSince1970) })
                    .prepare(wallet: wallet, intent: intent, ttl: 20)
                let payment = TOSQuantumPaymentCoordinator(outbox: store, baseDirectory: base, transport: { _ in proof }, signer: { entry, _, _ in
                    try TOSQuantumSigner.sign(role: .primary, purpose: .selfPay, seed: Data(repeating: 0x11, count: 32),
                        expectedPublicKey: entry.signingPublicKey, digest: entry.requestHash)
                }, broadcaster: { bytes, stopped in
                    _ = try rpc.call(method: "sendBocReturnHash", params: ["boc":bytes.base64EncodedString()], isCancelled: stopped)
                })
                let quote = try await payment.authorizeAndEstimate(prepared)
                try await payment.submit(quote)
            } else {
                // Negative chain fixture only: deliberately broadcast a valid
                // original request whose unaffordable output will be skipped.
                // Product quote/broadcast gates remain intact and are not used
                // as a bypass API; this public harness calls the node directly.
                let observation = try await accounts.observe(wallet: wallet, configIndices: [8, 19, 48])
                guard case .active(let state) = observation.snapshot.status else { return XCTFail("Public sender must already be deployed") }
                let now = UInt32(Date().timeIntervalSince1970)
                let time = max(now, max(try observation.network.masterchainTime(),
                    try observation.proof.provenAccountTime(expectedAddress: sender.address.toRaw())))
                let policy = try TOSRPCOrdinaryBOC.decode(observation.network.provenConfigParam(48).base64EncodedString())
                let request = try TOSQuantumSelfPayRequest(wallet: sender.address, state: state, role: .primary,
                    validUntil: time + 20, action: .execute(intent.actions()), provenTime: time, primaryPolicy: policy)
                let entry = try store.reserve(identity: sender, profile: profile, request: request, deploy: false, paymentIntent: intent)
                try store.signReserved(entry) {
                    try TOSQuantumSigner.sign(role: .primary, purpose: .selfPay, seed: Data(repeating: 0x11, count: 32),
                        expectedPublicKey: $0.signingPublicKey, digest: $0.requestHash)
                }
                let bytes = try XCTUnwrap(store.pending(identity: sender)?.signedBOC)
                try await background { _ = try rpc.call(method: "sendBocReturnHash", params: ["boc":bytes.base64EncodedString()]) }
            }
            let original = try XCTUnwrap(store.pending(identity: sender)), originalBOC = try XCTUnwrap(original.signedBOC)
            let rawFile = base.appendingPathComponent("outbox/" + sender.cell.hash().map { String(format: "%02x", $0) }.joined() + ".json")
            attach(try Data(contentsOf: rawFile), "original-public-entry.json"); attach(originalBOC, "exact-original-message.boc")
            let outcomes = TOSQuantumPaymentOutcomeReader(outbox: store, baseDirectory: base, accounts: { _ in
                TOSQuantumAccountReader(baseDirectory: base, transport: { proof })
            }, query: { flag in
                return { address, lt, hash in
                    let result = try rpc.call(method: "getTransactions", params: ["address":address,"lt":String(lt),
                        "hash":hash.base64EncodedString(),"limit":1], isCancelled: flag.stopped)
                    let items = try XCTUnwrap(result as? [[String: Any]])
                    let encoded = try XCTUnwrap(items.first?["data"] as? String)
                    let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
                    try lock.withLock {
                        guard transactions.count < 256, transactionBytes + bytes.count <= 16 * 1024 * 1024 else { throw TOSPQError.invalidInput }
                        transactions.append(bytes); transactionBytes += bytes.count
                    }
                    return encoded
                }
            })
            let expiries = TOSQuantumAuthorizationExpiryReader(outbox: store, baseDirectory: base, accounts: { _ in
                TOSQuantumAccountReader(baseDirectory: base, transport: { proof })
            })
            let retirement = try TOSQuantumRetirementCoordinator(outbox: store, baseDirectory: base, expiry: expiries, outcomes: outcomes)
            var ready: TOSQuantumRetirementCoordinator.Review?
            for _ in 0..<160 {
                do {
                    let candidate = try await retirement.review(wallet: wallet, operationID: original.id)
                    if candidate.outcome == (mismatch ? .includedWithoutExactTransfer : .senderSent) { ready = candidate; break }
                } catch TOSQuantumExpiredAuthorization.Error.notExpired(_, _) { }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            let review = try XCTUnwrap(ready, "Must obtain an actual exact-message receipt plus true proven shard expiry")
            XCTAssertGreaterThan(review.provenShardTime, review.deadline)
            XCTAssertEqual(review.entry.signedBOC, originalBOC); XCTAssertEqual(review.entry.requestBOC, original.requestBOC)
            let summary = try await retirement.complete(review)
            XCTAssertEqual(summary.outcome, mismatch ? .includedWithoutExactTransfer : .senderSent)
            XCTAssertNotNil(summary.transaction); XCTAssertEqual(summary.authorization.messageBytesHash, TOSQuantumRetirementCodec.hash(originalBOC))
            XCTAssertEqual(summary.authorization.operationID, original.id); XCTAssertNil(try store.pending(identity: sender))
            attach(try TOSQuantumRetirementCodec.encode(summary), "completed-local-record.json")
            let history = try await retirement.localHistory(wallet: wallet)
            XCTAssertEqual(history.count, 1)
        }
    }
}
