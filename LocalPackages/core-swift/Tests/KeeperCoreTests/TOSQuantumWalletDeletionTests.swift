import XCTest
import CoreComponents
@testable import KeeperCore

final class TOSQuantumWalletDeletionTests: XCTestCase {
    private enum Failure: Error { case injected }
    private final class Mnemonics: MnemonicsRepository {
        var validPassword = true, deleted = false, failDelete = false
        func hasMnemonics() -> Bool { !deleted }
        func checkIfPasswordValid(_ password: String) async -> Bool { validPassword }
        func deleteMnemonic(wallet: Wallet, password: String) async throws {
            if failDelete { throw Failure.injected }; deleted = true
        }
        func deleteAll() async throws { if failDelete { throw Failure.injected }; deleted = true }
        func getMnemonic(wallet: Wallet, password: String) async throws -> Mnemonic { throw Failure.injected }
        func saveMnemonic(_ mnemonic: Mnemonic, wallet: Wallet, password: String) async throws { throw Failure.injected }
        func saveMnemonic(_ mnemonic: Mnemonic, wallets: [Wallet], password: String) async throws { throw Failure.injected }
        func changePassword(oldPassword: String, newPassword: String) async throws { throw Failure.injected }
        func savePassword(_ password: String) throws { throw Failure.injected }
        func getPassword() throws -> String { throw Failure.injected }
        func deletePassword() throws { throw Failure.injected }
    }

    private func fixture() throws -> (Wallet, KeeperInfoStore, WalletsStore, URL) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tos-quantum-self-pay", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let identity = try TOSQuantumSelfPayIdentity(boc: XCTUnwrap(Data(base64Encoded: XCTUnwrap(fixture["identity_boc"] as? String))))
        let wallet = Wallet(id: UUID().uuidString, identity: WalletIdentity(network: .mainnet, kind: .Quantum(identity)),
            metaData: WalletMetaData(label: "Quantum", tintColor: .defaultColor, icon: .icon(.wallet)),
            setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = FileSystemVault<KeeperInfo, String>(fileManager: .default, directory: directory)
        let keeper = KeeperInfoStore(keeperInfoRepository: repository)
        return (wallet, keeper, WalletsStore(keeperInfoStore: keeper), directory)
    }

    func testQuantumCannotUseWatchOnlyDeletionOrAnInvalidPasscode() async throws {
        let (wallet, keeper, store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.addWallets([wallet])
        let mnemonics = Mnemonics(); mnemonics.validPassword = false
        var removed = 0
        let controller = WalletDeleteController(walletStore: store, keeperInfoStore: keeper, mnemonicsRepository: mnemonics,
            removeQuantumRole: { _, _ in removed += 1 })
        do { try await controller.deleteWallet(wallet: wallet); XCTFail("Quantum used watch-only deletion") }
        catch TOSPQError.keyBinding {}
        do { try await controller.deleteWallet(wallet: wallet, passcode: "wrong"); XCTFail("Wrong passcode accepted") }
        catch TOSPQError.keyBinding {}
        XCTAssertEqual(removed, 0); XCTAssertFalse(mnemonics.deleted)
        XCTAssertEqual(store.wallets.map(\.id), [wallet.id])
    }

    func testCustodyFailurePreservesRegistrationAndRecoveryThenRetryDeletesBothRoles() async throws {
        let (wallet, keeper, store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.addWallets([wallet])
        let mnemonics = Mnemonics()
        var fail = true, roles = [TOSQuantumRole]()
        let controller = WalletDeleteController(walletStore: store, keeperInfoStore: keeper, mnemonicsRepository: mnemonics,
            removeQuantumRole: { id, role in
                XCTAssertEqual(id.uuidString, wallet.id); roles.append(role)
                if fail && role == .rescue { throw Failure.injected }
            })
        do { try await controller.deleteWallet(wallet: wallet, passcode: "valid"); XCTFail("Lost custody error") }
        catch Failure.injected {}
        XCTAssertEqual(roles, [.primary, .rescue]); XCTAssertFalse(mnemonics.deleted)
        XCTAssertEqual(store.wallets.map(\.id), [wallet.id])
        fail = false; roles.removeAll()
        try await controller.deleteWallet(wallet: wallet, passcode: "valid")
        XCTAssertEqual(roles, [.primary, .rescue]); XCTAssertTrue(mnemonics.deleted); XCTAssertTrue(store.wallets.isEmpty)
    }

    func testSignOutClearsAllRoleRecordsIncludingUnregisteredAttemptsBeforePublishingEmptyState() async throws {
        let (wallet, keeper, store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.addWallets([wallet])
        let mnemonics = Mnemonics()
        var fail = true, calls = 0
        let controller = WalletDeleteController(walletStore: store, keeperInfoStore: keeper, mnemonicsRepository: mnemonics,
            removeAllQuantumRoles: { calls += 1; if fail { throw Failure.injected } })
        do { try await controller.deleteAll(); XCTFail("Lost sign-out error") } catch Failure.injected {}
        XCTAssertEqual(calls, 1); XCTAssertFalse(mnemonics.deleted); XCTAssertEqual(store.wallets.count, 1)
        fail = false; mnemonics.failDelete = true
        do { try await controller.deleteAll(); XCTFail("Lost mnemonic cleanup error") } catch Failure.injected {}
        XCTAssertEqual(store.wallets.count, 1)
        mnemonics.failDelete = false
        try await controller.deleteAll()
        XCTAssertEqual(calls, 3); XCTAssertTrue(mnemonics.deleted); XCTAssertTrue(store.wallets.isEmpty)
    }
}
