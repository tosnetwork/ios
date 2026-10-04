import XCTest
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSPQWalletTests: XCTestCase {
    func testExportPublicMobileSignaturesForNativeVM() throws {
        for algorithm in [TOSPQAlgorithm.mldsa44, .falcon512Padded] {
            XCTAssertEqual(algorithm.minimumVM, 16)
            let seed = Data(repeating: 0xa0, count: 32) // PUBLIC TEST DATA only.
            let pk = try TOSPQSigner.publicKey(algorithm: algorithm, seed: seed)
            let wallet = try TOSPQWallet(algorithm: algorithm, publicKey: pk, network: 3)
            let payload = try wallet.transferPayload(destination: Address(workchain: 0, hash: Data(repeating: 0x22, count: 32)),
                                                      nanotomi: 10000000, comment: "PQ TOS 测试 🌌")
            let now = UInt32(ProcessInfo.processInfo.environment["TOS_PQ_CHAIN_TIME"] ?? "") ?? 1780000000
            let nonceText = (ProcessInfo.processInfo.environment["TOS_PQ_NONCE"] ?? "0").split(separator: ",")
            let nonce = UInt64(String(nonceText.count == 2 ? nonceText[Int(algorithm.rawValue) - 1] : nonceText.first ?? "0")) ?? 0
            let request = try wallet.request(epoch: 0, nonce: nonce, validUntil: now + 600, now: now, payload: payload)
            let message = try wallet.signingMessage(request: request)
            let signature = try TOSPQSigner.sign(algorithm: algorithm, seed: seed, expectedPublicKey: pk, message: message)
            func boc(_ cell: Cell) throws -> String { try cell.toBoc().base64EncodedString() }
            let record: [String: Any] = ["platform": "ios", "algorithm": algorithm.rawValue, "chain_time": now, "nonce": nonce,
                "public_key": pk.map { String(format: "%02x", $0) }.joined(),
                "module_address": wallet.moduleAddress.toRaw(), "wallet_address": wallet.address.toRaw(),
                "module_code": try boc(wallet.moduleCode), "module_data": try boc(wallet.moduleData),
                "wallet_code": try boc(wallet.walletCode), "wallet_data": try boc(wallet.walletData),
                "request": try boc(request), "submission": try boc(wallet.submission(request: request, signature: signature))]
            let raw = try JSONSerialization.data(withJSONObject: record, options: .sortedKeys)
            print("TOS_PQ_PUBLIC_WIRE_JSON=" + String(decoding: raw, as: UTF8.self))
        }
    }
    func testIndependentChainWireGoldenCommitments() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tos-pq-auth-vectors", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let vectors = try XCTUnwrap(object["vectors"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 2)
        for vector in vectors {
            let algorithm = try XCTUnwrap(TOSPQAlgorithm(rawValue: Int32(try XCTUnwrap(vector["algorithm"] as? Int))))
            func bytes(_ name: String) throws -> Data { try XCTUnwrap(Data(hex: try XCTUnwrap(vector[name] as? String))) }
            let wallet = try TOSPQWallet(algorithm: algorithm, publicKey: bytes("public_key"), network: 3)
            XCTAssertEqual(wallet.moduleAddress.toRaw(), vector["module_address"] as? String)
            XCTAssertEqual(wallet.address.toRaw(), vector["wallet_address"] as? String)
            let payload = try Builder().store(uint: 123, bits: 32).endCell()
            let request = try wallet.request(epoch: 0, nonce: 0, validUntil: 2000000600, now: 2000000000, payload: payload)
            let message = try wallet.signingMessage(request: request)
            XCTAssertEqual(message, try bytes("signing_message"))
            let signature = try bytes("signature")
            XCTAssertTrue(TOSPQSigner.verify(algorithm: algorithm, publicKey: wallet.publicKey, message: message, signature: signature))
            XCTAssertEqual(try wallet.submission(request: request, signature: signature).hash(), try bytes("submission_hash"))
            let counters = try wallet.authCounters(code: wallet.walletCode, data: wallet.walletData)
            XCTAssertEqual(counters.epoch, 0); XCTAssertEqual(counters.nonce, 0)
            let other = try wallet.request(epoch: 0, nonce: 1, validUntil: 2000000600, now: 2000000000, payload: payload)
            XCTAssertFalse(TOSPQSigner.verify(algorithm: algorithm, publicKey: wallet.publicKey,
                message: try wallet.signingMessage(request: other), signature: signature))
            XCTAssertThrowsError(try wallet.authCounters(code: wallet.moduleCode, data: wallet.walletData))
            XCTAssertThrowsError(try wallet.request(epoch: 0, nonce: 0, validUntil: 2000000000, now: 2000000000, payload: payload))
            XCTAssertThrowsError(try wallet.request(epoch: 0, nonce: .max, validUntil: 2000000600, now: 2000000000, payload: payload))
        }
    }
}
