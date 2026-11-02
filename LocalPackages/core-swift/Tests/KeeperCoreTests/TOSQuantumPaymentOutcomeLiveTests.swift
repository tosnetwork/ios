import XCTest
import Foundation
import BigInt
import TonSwift
import CoreComponents
@testable import KeeperCore

/// Real isolated-chain execution with the public fixture signer. This verifies
/// core reconciliation, not protected phone custody or the final App flow.
final class TOSQuantumPaymentOutcomeLiveTests: XCTestCase {
    private func background<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func testLiveExactPaymentSurvivesNewerHistoryAndRejectsForeignCursor() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["TOS_QUANTUM_ROOT_HASH"], !root.isEmpty,
              let file = env["TOS_QUANTUM_FILE_HASH"], !file.isEmpty,
              env["TOS_QUANTUM_GLOBAL_ID"] == "1", let endpoint = env["TOS_UI_RPC_URL"],
              let url = URL(string: endpoint + "/jsonRPC") else {
            throw XCTSkip("Requires an isolated funded public-fixture chain; no phone custody claim")
        }
        let resources = try XCTUnwrap(Bundle.module.url(forResource: "quantum-self-pay-live", withExtension: nil))
        let registry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            resources.appendingPathComponent("public-self-pay-accounts.json"))) as? [String: Any])
        let rows = try XCTUnwrap(registry["accounts"] as? [String: [String: Any]])
        func identity(_ name: String) throws -> TOSQuantumSelfPayIdentity {
            try TOSQuantumSelfPayIdentity(boc: XCTUnwrap(Data(base64Encoded: XCTUnwrap(rows[name]?["identity_boc"] as? String))))
        }
        let sender = try identity("active"), recipient = try identity("absent"), id = UUID()
        let profile = try TOSQuantumNetworkProfile(globalID: 1, rootHash: root, fileHash: file)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try TOSQuantumCreationRecord(id: id, profile: profile, identity: sender).save(baseDirectory: base)
        let outbox = try TOSQuantumOutbox(baseDirectory: base.appendingPathComponent("outbox"))
        let wallet = Wallet(id: id.uuidString,
            identity: WalletIdentity(network: .mainnet, kind: .Quantum(sender), networkGlobalId: 1),
            metaData: WalletMetaData(label: "Public live fixture", tintColor: .defaultColor, icon: .icon(.wallet)),
            setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
        let traceLock = NSLock()
        var materials = [(Data, Data)](), transactionBOCs = [Data]()
        var capturedEntry: TOSQuantumOutbox.Entry?
        var receiptSummary: [String: Any]?
        func attach(_ data: Data, _ name: String) {
            let value = XCTAttachment(data: data, uniformTypeIdentifier: "public.data")
            value.name = name; value.lifetime = .keepAlways; add(value)
        }
        defer {
            if let entry = capturedEntry ?? (try? outbox.pending(identity: sender)),
               let data = try? JSONEncoder().encode(entry) {
                attach(data, "public-outbox-entry.json")
                if let bytes = entry.signedBOC { attach(bytes, "exact-signed-message.boc") }
            }
            if let data = try? profile.anchor() { attach(data, "anchor.json") }
            if let summary = receiptSummary, let data = try? JSONSerialization.data(withJSONObject: summary) {
                attach(data, "receipt.json")
            }
            let traces = traceLock.withLock { (materials, transactionBOCs) }
            for (index, pair) in traces.0.enumerated() {
                attach(pair.0, "proof-query-\(index).tl"); attach(pair.1, "proof-response-\(index).tl")
            }
            for (index, bytes) in traces.1.enumerated() { attach(bytes, "transaction-\(index).boc") }
        }
        let relay = try TOSQuantumProofHTTPTransport(endpoint: url)
        let proof: TOSQuantumProofBridge.Transport = { query, capacity in
            let response = try relay.query(query, maximumBytes: capacity)
            traceLock.withLock { materials.append((query, response)) }
            return response
        }
        let anchor = try profile.anchor()
        try await background {
            let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: anchor, baseDirectory: base)
            _ = try session.enrollBound(request: TOSQuantumSelfPayNetwork.request(maximumAge: 300),
                now: Int64(Date().timeIntervalSince1970), transport: proof)
        }
        let accounts = TOSQuantumAccountReader(baseDirectory: base, transport: { proof })
        let service = TOSQuantumPaymentService(reader: accounts, now: { Int64(Date().timeIntervalSince1970) })
        let rpc = try TOSQuantumRPCTransport(endpoint: url)
        let coordinator = TOSQuantumPaymentCoordinator(outbox: outbox, baseDirectory: base,
            transport: { _ in proof }, signer: { entry, _, _ in
                try TOSQuantumSigner.sign(role: entry.role, purpose: .selfPay, seed: Data(repeating: 0x11, count: 32),
                    expectedPublicKey: entry.signingPublicKey, digest: entry.requestHash)
            }, broadcaster: { bytes, stopped in
                _ = try rpc.call(method: "sendBocReturnHash", params: ["boc": bytes.base64EncodedString()], isCancelled: stopped)
            })
        let intent = try TOSQuantumPaymentIntent(recipient: recipient.address, amount: 10_000_000_000,
            bounce: false, comment: "Receipt 🌸")
        let prepared = try await service.prepare(wallet: wallet, intent: intent, ttl: 300)
        let quote = try await coordinator.authorizeAndEstimate(prepared)
        try await coordinator.submit(quote)
        let stored = try XCTUnwrap(outbox.pending(identity: sender))
        capturedEntry = stored
        let reader = TOSQuantumPaymentOutcomeReader(outbox: outbox, baseDirectory: base, accounts: { flag in
            TOSQuantumAccountReader(baseDirectory: base, transport: {
                let cancellable = try TOSQuantumProofHTTPTransport(endpoint: url)
                return { query, capacity in
                    let response = try cancellable.query(query, maximumBytes: capacity, isCancelled: flag.stopped)
                    traceLock.withLock { materials.append((query, response)) }; return response
                }
            })
        }, query: { flag in
            return { address, lt, hash in
                let result = try rpc.call(method: "getTransactions", params: ["address":address, "lt":String(lt),
                    "hash":hash.base64EncodedString(), "limit":1], isCancelled: flag.stopped)
                let items = try XCTUnwrap(result as? [[String: Any]])
                XCTAssertEqual(items.count, 1)
                let encoded = try XCTUnwrap(items.first?["data"] as? String)
                let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
                traceLock.withLock { transactionBOCs.append(bytes) }
                return encoded
            }
        })
        func awaitNonce(_ nonce: UInt64) async throws {
            for _ in 0..<80 {
                let observation = try await accounts.observe(wallet: wallet)
                if case .active(let state) = observation.snapshot.status, state.primaryNonce >= nonce { return }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            XCTFail("Signed fixture message was not included"); throw TOSPQError.invalidInput
        }
        func nonce(_ request: TOSQuantumSelfPayRequest) throws -> UInt64 {
            let s = try request.request.beginParse()
            try s.skip(32 + 32 + 256)
            let _: Address = try s.loadType()
            try s.skip(256 + 8 + 64)
            return try s.loadUint(bits: 64)
        }
        try await awaitNonce(nonce(prepared.request) + 1)

        // Independent public-fixture activity models another installation. It
        // deliberately does not use or release the product's occupied outbox.
        func laterFixtureActivity() async throws -> UInt64 {
            let tiny = try TOSQuantumPaymentIntent(recipient: recipient.address, amount: 1_000_000_000, bounce: false)
            let p = try await service.prepare(wallet: wallet, intent: tiny, ttl: 300)
            let signature = try TOSQuantumSigner.sign(role: .primary, purpose: .selfPay,
                seed: Data(repeating: 0x11, count: 32), expectedPublicKey: p.request.signingPublicKey, digest: p.request.digest)
            let bytes = try sender.wallet.external(body: p.request.submission(signature: signature), deploy: false).toBoc()
            try await background {
                _ = try rpc.call(method: "sendBocReturnHash", params: ["boc":bytes.base64EncodedString()])
            }
            let used = try nonce(p.request)
            try await awaitNonce(used + 1)
            return used
        }
        for _ in 0..<21 { _ = try await laterFixtureActivity() }
        let first = try await reader.read(wallet: wallet, limit: 20)
        XCTAssertEqual(first.operationID, stored.id); XCTAssertEqual(first.scannedCount, 20)
        XCTAssertNil(first.receipt)
        let cursor = try XCTUnwrap(first.next)

        // Advancing the real head must not restart/replace the captured cursor.
        _ = try await laterFixtureActivity()
        let second = try await reader.read(wallet: wallet, cursor: cursor, limit: 2)
        XCTAssertEqual(second.scannedCount, 2)
        let receipt = try XCTUnwrap(second.receipt)
        XCTAssertEqual(receipt.operationID, stored.id); XCTAssertEqual(receipt.intent, intent)
        XCTAssertEqual(receipt.outcome, .senderSent)
        XCTAssertNil(second.next)
        XCTAssertEqual(second.authorizationExpired, second.provenShardTime > prepared.expiresAt)
        receiptSummary = ["operation":stored.id.uuidString,
            "transaction_hash":receipt.transactionHash.map { String(format:"%02x",$0) }.joined(),
            "logical_time":String(receipt.logicalTime), "sender_sent":receipt.outcome == .senderSent,
            "recipient_credit_verified":false, "cursor_head_advanced":true,
            "first_page_count":first.scannedCount, "second_page_count":second.scannedCount,
            "proven_shard_time":second.provenShardTime, "original_deadline":prepared.expiresAt,
            "authorization_expired":second.authorizationExpired, "slot_phase":"unknown"]
        XCTAssertEqual(try outbox.pending(identity: sender)?.phase, .unknown)
        XCTAssertEqual(try outbox.pending(identity: sender)?.signedBOC, stored.signedBOC)

        let otherID = UUID()
        try TOSQuantumCreationRecord(id: otherID, profile: profile, identity: sender).save(baseDirectory: base)
        try await background {
            let session = try TOSQuantumProofSession(walletID: otherID, locallyProvisionedAnchor: anchor, baseDirectory: base)
            _ = try session.enrollBound(request: TOSQuantumSelfPayNetwork.request(maximumAge: 300),
                now: Int64(Date().timeIntervalSince1970), transport: proof)
        }
        let otherWallet = Wallet(id: otherID.uuidString, identity: wallet.identity, metaData: wallet.metaData,
            setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
        do { _ = try await reader.read(wallet: otherWallet, cursor: cursor); XCTFail("Foreign wallet ID reused receipt cursor") }
        catch { guard case TOSQuantumPaymentOutcomeReader.Error.binding = error else { return XCTFail("Wrong rejection: \(error)") } }

    }
}
