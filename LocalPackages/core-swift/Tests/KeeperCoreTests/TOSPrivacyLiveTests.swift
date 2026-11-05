import CoreComponents
import Foundation
import TonSwift
@testable import KeeperCore
import XCTest

/// Opt-in integration against a separately provisioned, empty isolated pool.
/// This exercises App readers and native replay, not the user-facing payment flow.
final class TOSPrivacyLiveTests: XCTestCase {
    func testAuthenticatedPoolObservationAndCompleteHistory() async throws {
        guard let encoded = ProcessInfo.processInfo.environment["TOS_PRIVACY_LIVE_CONFIG"], !encoded.isEmpty else {
            throw XCTSkip("Set TOS_PRIVACY_LIVE_CONFIG to the isolated live-pool configuration")
        }
        let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertLessThanOrEqual(bytes.count, 131_072)
        try await Task.detached {
            let config = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            func string(_ name: String) throws -> String { try XCTUnwrap(config[name] as? String) }
            func hash(_ name: String) throws -> Data {
                let text = try string(name)
                guard text.count == 64, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw TOSPQError.invalidInput
                }
                let chars = Array(text.utf8)
                func nibble(_ b: UInt8) -> UInt8 { b <= 57 ? b - 48 : b - 87 }
                return Data(stride(from: 0, to: 64, by: 2).map { nibble(chars[$0]) << 4 | nibble(chars[$0 + 1]) })
            }
            let url = try XCTUnwrap(URL(string: string("rpc")))
            guard url.scheme == "http", url.host == "127.0.0.1" else { throw TOSPQError.invalidInput }
            let profile = try TOSQuantumNetworkProfile(globalID: 3, rootHash: string("root_hash"), fileHash: string("file_hash"))
            let address = Address(workchain: 0, hash: try hash("pool_account"))
            let code = try TOSRPCOrdinaryBOC.decode(string("code_boc"))
            let assets = try XCTUnwrap(Bundle.module.url(forResource: "quantum-self-pay-live", withExtension: nil))
            let publicData = try Data(contentsOf: assets.appendingPathComponent("public-self-pay-accounts.json"))
            let publicObject = try XCTUnwrap(JSONSerialization.jsonObject(with: publicData) as? [String: Any])
            let accounts = try XCTUnwrap(publicObject["accounts"] as? [String: [String: Any]])
            let original = try TOSQuantumSelfPayIdentity(boc: XCTUnwrap(Data(base64Encoded: XCTUnwrap(accounts["active"]?["identity_boc"] as? String))))
            let a = original.wallet.initialAuthority
            let identity = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority:
                TOSQuantumSelfPayAuthority(globalID: 3, namespace: a.namespace, primaryKey: a.primaryKey, rescueKey: a.rescueKey)))
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: base) }
            let id = UUID(), relay = try TOSQuantumProofHTTPTransport(endpoint: url)
            let transport: TOSQuantumProofBridge.Transport = { query, capacity in try relay.query(query, maximumBytes: capacity) }
            func now() -> Int64 { Int64(Date().timeIntervalSince1970) }
            let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: profile.anchor(), baseDirectory: base)
            let request = try JSONSerialization.data(withJSONObject: ["mode": "live", "max_age_seconds": 300, "config_params": [19, 21]])
            _ = try session.enrollBound(request: request, now: now(), transport: transport)
            let reader = TOSQuantumAccountReader(baseDirectory: base, transport: { transport }, now: now)
            let profileHash = try hash("profile_hash"), manifestHash = try hash("poseidon_manifest_hash"), vkHash = try hash("groth16_vk_hash")
            let observation = try reader.observePool(id: id, identity: identity, profile: profile, address: address,
                expectedCode: code, profileHash: profileHash, manifestHash: manifestHash, verifyingKeyHash: vkHash)
            let rpc = try TOSQuantumRPCTransport(endpoint: url)
            let completed = try TOSPrivacyHistorySynchronizer.synchronize(observation: observation, query: { raw, lt, hash in
                let result = try rpc.call(method: "getTransactions", params: ["address": raw, "limit": 1,
                    "lt": String(lt), "hash": hash.base64EncodedString()])
                let rows = try XCTUnwrap(result as? [[String: Any]])
                XCTAssertEqual(rows.count, 1)
                return try XCTUnwrap(Data(base64Encoded: XCTUnwrap(rows.first?["data"] as? String)))
            }, stopped: { false }, now: now)
            defer { completed.close() }
            XCTAssertFalse(try completed.transactions().isEmpty)
            let info = try XCTUnwrap(JSONSerialization.jsonObject(with: completed.info(now: now())) as? [String: Any])
            XCTAssertEqual(info["total_outputs"] as? String, "0")
            XCTAssertEqual(info["native_liability"] as? String, "0")
            var seed = Data(repeating: 0x42, count: 32)
            let summary = try XCTUnwrap(JSONSerialization.jsonObject(with:
                completed.summaryAndWipeSeed(seed: &seed, stopped: { false }, now: now)) as? [String: Any])
            XCTAssertEqual(summary["total_outputs"] as? String, "0")
            XCTAssertEqual(summary["unspent_balance"] as? String, "0")
            XCTAssertEqual(seed, Data(repeating: 0, count: 32))
            seed = Data(repeating: 0x42, count: 32)
            XCTAssertThrowsError(try completed.summaryAndWipeSeed(seed: &seed, stopped: { true }, now: now))
            XCTAssertEqual(seed, Data(repeating: 0, count: 32))
            var clockReads = 0
            let initialTime = now()
            seed = Data(repeating: 0x42, count: 32)
            XCTAssertThrowsError(try completed.summaryAndWipeSeed(seed: &seed, stopped: { false }, now: {
                clockReads += 1
                return initialTime + (clockReads == 1 ? 0 : 601)
            }))
            XCTAssertEqual(clockReads, 2, "The live clock must be sampled after native scanning too")
            XCTAssertEqual(seed, Data(repeating: 0, count: 32))
            // A positive read above establishes the transport before testing the binding refusal.
            XCTAssertThrowsError(try reader.observePool(id: id, identity: identity, profile: profile, address: address,
                expectedCode: code, profileHash: Data(repeating: 0, count: 32), manifestHash: manifestHash, verifyingKeyHash: vkHash)) { error in
                guard case TOSPQError.keyBinding = error else { return XCTFail("Expected profile binding refusal: \(error)") }
            }
            completed.close()
            XCTAssertThrowsError(try completed.info(now: now()))
            seed = Data(repeating: 0x42, count: 32)
            XCTAssertThrowsError(try completed.summaryAndWipeSeed(seed: &seed, stopped: { false }, now: now))
            XCTAssertEqual(seed, Data(repeating: 0, count: 32))
        }.value
    }
}
