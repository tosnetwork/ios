import XCTest
import Foundation
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSV5R2InitialRecoveryTests: XCTestCase {
    private func setup() throws -> (String, TOSV5R2Codes, TOSV5R2CodePins, Address) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tos-v5r2-initial-recovery", withExtension: "json"))
        let text = try String(contentsOf: url, encoding: .utf8)
        func tag(_ n: UInt8) throws -> Cell { try Builder().store(uint: n, bits: 8).endCell() }
        let codes = try TOSV5R2Codes(wallet: tag(1), module: tag(2), vault: tag(3))
        let pins = TOSV5R2CodePins(wallet: codes.wallet.hash(), module: codes.module.hash(), vault: codes.vault.hash())
        return (text, codes, pins, Address(workchain: 0, hash: Data(hex: "017b4078cbfce4b21954669c79ed5f9785176eae6518e8f3bb9448ed2ab12b46")))
    }
    func testIndependentManifestAndDisplayOnlyEpochHint() throws {
        let (text, codes, pins, address) = try setup()
        let m = try TOSV5R2InitialRecovery.parseAndReconstruct(Data(text.utf8), codes: codes, pins: pins, expectedWallet: address)
        XCTAssertEqual(m.genesis.address, address); XCTAssertEqual(m.lastObservedEpoch, UInt64.max)
        XCTAssertEqual(m.derivation.primary_seed_profile, .rawMaster32)
        let changed = text.replacingOccurrences(of: "18446744073709551615", with: "null")
        XCTAssertEqual(try TOSV5R2InitialRecovery.parseAndReconstruct(Data(changed.utf8), codes: codes, pins: pins, expectedWallet: address).genesis.address, address)
    }
    func testStrictFieldsAndIndependentTrust() throws {
        let (text, codes, pins, address) = try setup()
        func refused(_ input: String, expected: Address? = nil) {
            XCTAssertThrowsError(try TOSV5R2InitialRecovery.parseAndReconstruct(Data(input.utf8), codes: codes, pins: pins, expectedWallet: expected ?? address))
        }
        refused("{\"schema\":\"TOS-WALLET-V5R2-INITIAL-RECOVERY-v1\"," + text.dropFirst())
        refused("{\"\\u0073chema\":\"TOS-WALLET-V5R2-INITIAL-RECOVERY-v1\"," + text.dropFirst())
        refused("{\"schema\":\"fake\"," + text.dropFirst())
        refused("{\"secret\":\"never-allowed\"," + text.dropFirst())
        refused(text.replacingOccurrences(of: "\"wallet_id\": 42", with: "\"wallet_id\": \"42\""))
        refused(text.replacingOccurrences(of: "\"wallet_id\": 42", with: "\"wallet_id\": 4294967296"))
        refused(text.replacingOccurrences(of: "\"wallet_id\": 42", with: "\"wallet_id\": 42.0"))
        refused(text, expected: Address(workchain: 0, hash: Data(count: 32)))
        refused(text.replacingOccurrences(of: "1d54665e5652d75d891c35b1c80b09c52b5186c28b2533ed054feb9c51b85876", with: String(repeating: "00", count: 32)))
        refused("{\"derivation\":{\"deep\":{}}}")
        refused(String(repeating: " ", count: 16385))
    }
    func testMalformedEncodingDoesNotEchoInput() throws {
        let (_, codes, pins, address) = try setup()
        let marker = "PRIVATE_RECOVERY_INPUT"
        do {
            _ = try TOSV5R2InitialRecovery.parseAndReconstruct(Data("{\"schema\":\"\(marker)\"} garbage".utf8), codes: codes, pins: pins, expectedWallet: address)
            XCTFail("malformed input accepted")
        } catch {
            XCTAssertFalse(String(describing: error).contains(marker))
            guard let value = error as? TOSPQError, case .invalidInput = value else { XCTFail("Expected generic encoding rejection"); return }
        }
    }
    func testPreparedPublicMetadataMatchesCorpusAndRoundTrips() throws {
        let (text, codes, pins, address) = try setup()
        var network = Data(count: 32); network[31] = 123
        var tree = Data(count: 32); tree[30] = 1; tree[31] = 0xc8
        let key: Data = Data(hex: "000000010000000800000003" + String(repeating: "33", count: 16) + String(repeating: "44", count: 32))
        let d = TOSV5R2InitialRecovery.Derivation(account: 0, generation: 0, primary: .rawMaster32, rescue: .rawMaster32, fee: .rawMaster32)
        let m = try TOSV5R2InitialRecovery.prepare(codes: codes, pins: pins, globalId: 42, network: network, walletId: 42,
            primaryKey: Data(repeating: 0x11, count: 1312), rescueKey: Data(repeating: 0x22, count: 32), policy: .ready,
            tree: tree, feeKey: key, epoch0: 1779992790, derivation: d)
        let expected = try JSONSerialization.jsonObject(with: Data(text.replacingOccurrences(of: "18446744073709551615", with: "null").utf8)) as? NSDictionary
        XCTAssertEqual(try JSONSerialization.jsonObject(with: m.toJson()) as? NSDictionary, expected)
        XCTAssertEqual(try TOSV5R2InitialRecovery.parseAndReconstruct(m.toJson(), codes: codes, pins: pins, expectedWallet: address).genesis.address, address)
        var copy = m.toJson(); copy.resetBytes(in: 0..<copy.count)
        XCTAssertEqual(try TOSV5R2InitialRecovery.parseAndReconstruct(m.toJson(), codes: codes, pins: pins, expectedWallet: address).genesis.address, address)
    }
}
