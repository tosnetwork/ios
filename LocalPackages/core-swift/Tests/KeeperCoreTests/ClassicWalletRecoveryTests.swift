import XCTest
import BigInt
import TonSwift
import CoreComponents
@testable import KeeperCore

final class ClassicWalletRecoveryTests: XCTestCase {
    private func model(_ revision: WalletContractVersion, value: BigUInt = 0,
                       indexed: Bool = false, complete: Bool = true, known: Bool = true, active: Bool = false) -> ActiveWalletModel {
        let number = WalletContractVersion.allCases.firstIndex(of: revision)! + 1
        let address = Address(workchain: 0, hash: Data(repeating: UInt8(number), count: 32))
        return ActiveWalletModel(id: address.toRaw(), revision: revision, address: address,
            isActive: active || value > 0, balance: Balance(tonBalance: TonBalance(amount: value), jettonsBalance: []),
            nfts: [], assetDiscoveryComplete: complete, hasIndexedAssets: indexed, accountStateKnown: known)
    }
    func testEveryAssetOrUnknownAccountSurvivesWithoutAddingEmptyDefault() throws {
        let models = [model(.v5R1), model(.v4R2, value: (BigUInt(1) << 119) + 1),
                      model(.v3R2, indexed: true), model(.v3R1, complete: false), model(.v4R1, known: false)]
        XCTAssertEqual(try ClassicWalletRecovery.select(models, fallback: .v5R1).map(\.revision), [.v4R2, .v4R1, .v3R2, .v3R1])
    }
    func testOnlyKnownEmptyCandidatesUseOriginalFormatFallback() throws {
        XCTAssertEqual(try ClassicWalletRecovery.select([model(.v4R2), model(.v5R1)], fallback: .v5R1).map(\.revision), [.v5R1])
        XCTAssertEqual(try ClassicWalletRecovery.select([model(.tosV5R1)], fallback: .tosV5R1).map(\.revision), [.tosV5R1])
        XCTAssertThrowsError(try ClassicWalletRecovery.select([model(.v4R2)], fallback: .v5R1))
    }
    func testDeployedZeroBalanceAccountKeepsItsOriginalAddress() throws {
        let deployed = model(.v4R2, active: true)
        let result = try ClassicWalletRecovery.select([model(.v5R1), deployed], fallback: .v5R1)
        XCTAssertEqual(result.map(\.revision), [.v4R2])
        XCTAssertEqual(result.first?.address, deployed.address)
    }
    func testActiveAndFrozenStatesRemainDeployedAtZeroBalance() throws {
        for status in ["active", "frozen"] {
            let state = try TOSRecoveryAccount.parse(["state": status, "balance": "0"])
            XCTAssertTrue(state.deployed)
            XCTAssertEqual(state.amount, 0)
        }
        for status in ["uninit", "uninitialized", "nonexist"] {
            XCTAssertFalse(try TOSRecoveryAccount.parse(["state": status, "balance": "0"]).deployed)
        }
    }
    func testRecoveryAccountRejectsMalformedStateAndUnsignedOverflow() throws {
        let amount = (BigUInt(1) << 120) - 1
        XCTAssertEqual(try TOSRecoveryAccount.parse(["state": "active", "balance": amount.description]).amount, amount)
        for balance: Any in ["-1", "+1", " 1", "1.0", "", "9" + String(repeating: "0", count: 1000), (amount + 1).description, 1] {
            XCTAssertThrowsError(try TOSRecoveryAccount.parse(["state": "active", "balance": balance]))
        }
        XCTAssertThrowsError(try TOSRecoveryAccount.parse(["state": "unknown", "balance": "0"]))
    }
    func testInvalidOrDuplicateDiscoveryRefusesBeforeSelection() throws {
        XCTAssertThrowsError(try ClassicWalletRecovery.select([], fallback: .v5R1))
        XCTAssertThrowsError(try ClassicWalletRecovery.select([model(.v5R1), model(.v5R1)], fallback: .v5R1))
        let many = (0..<65).map { value in
            ActiveWalletModel(id: "\(value)", revision: .v5R1,
                address: Address(workchain: 0, hash: Data(repeating: UInt8(value), count: 32)),
                isActive: false, balance: Balance(tonBalance: TonBalance(amount: 0), jettonsBalance: []), nfts: [])
        }
        XCTAssertThrowsError(try ClassicWalletRecovery.select(many, fallback: .v5R1))
    }
    func testNumericLabelsPreserveUserTextWithoutVersionSuffixes() throws {
        XCTAssertEqual(try ClassicWalletRecovery.labels(base: "Savings", count: 3), ["Savings 1", "Savings 2", "Savings 3"])
        XCTAssertEqual(try ClassicWalletRecovery.labels(base: "My v4 wallet", count: 1), ["My v4 wallet"])
        XCTAssertThrowsError(try ClassicWalletRecovery.labels(base: "Wallet", count: 0))
        XCTAssertThrowsError(try ClassicWalletRecovery.labels(base: "Wallet", count: 65))
    }
    func testIndexCompletenessMustBeBooleanAndBothListsMustBeKnown() throws {
        func tokens(_ rows: [[String: Any]], _ complete: Any) -> [String: Any] {
            ["@type": "wallet.accountTokens", "tokens": rows, "index_state": ["complete": complete]]
        }
        func nfts(_ rows: [[String: Any]], _ complete: Any) -> [String: Any] {
            ["@type": "wallet.accountNfts", "nfts": rows, "index_state": ["complete": complete]]
        }
        XCTAssertTrue(try TOSRecoveryAssets.parse(tokens: tokens([], true), nfts: nfts([], true)).complete)
        XCTAssertFalse(try TOSRecoveryAssets.parse(tokens: tokens([], false), nfts: nfts([], true)).complete)
        XCTAssertFalse(try TOSRecoveryAssets.parse(tokens: tokens([], "true"), nfts: nfts([], true)).complete)
        XCTAssertFalse(try TOSRecoveryAssets.parse(tokens: tokens([], 1), nfts: nfts([], true)).complete)
        XCTAssertTrue(try TOSRecoveryAssets.parse(tokens: tokens([["token_wallet": "public"]], true), nfts: nfts([], true)).hasAssets)
        XCTAssertTrue(try TOSRecoveryAssets.parse(tokens: tokens([], true), nfts: nfts([["nft_item": "public"]], true)).hasAssets)
        XCTAssertThrowsError(try TOSRecoveryAssets.parse(tokens: tokens([[:]], true), nfts: nfts([], true)))
        XCTAssertThrowsError(try TOSRecoveryAssets.parse(tokens: tokens([[:], [:]], true), nfts: nfts([], true)))
    }
}
