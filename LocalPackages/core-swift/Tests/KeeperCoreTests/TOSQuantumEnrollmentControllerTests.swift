import XCTest
import CoreComponents
import TonSwift
import TronSwift
@testable import KeeperCore

final class TOSQuantumEnrollmentControllerTests: XCTestCase {
    private enum Failure: Swift.Error { case injected }
    private final class Mnemonics: MnemonicsRepository {
        var hasVault = true, valid = true, reads = 0, checks = 0, removed = [String]()
        func hasMnemonics() -> Bool { hasVault }
        func checkIfPasswordValid(_ password: String) async -> Bool { checks += 1; return valid }
        func getMnemonic(wallet: Wallet, password: String) async throws -> CoreComponents.Mnemonic { reads += 1; throw Failure.injected }
        func deleteMnemonic(wallet: Wallet, password: String) async throws { removed.append(wallet.id) }
        func saveMnemonic(_ mnemonic: CoreComponents.Mnemonic, wallet: Wallet, password: String) async throws { throw Failure.injected }
        func saveMnemonic(_ mnemonic: CoreComponents.Mnemonic, wallets: [Wallet], password: String) async throws { throw Failure.injected }
        func changePassword(oldPassword: String, newPassword: String) async throws { throw Failure.injected }
        func deleteAll() async throws { throw Failure.injected }
        func savePassword(_ password: String) throws { throw Failure.injected }
        func getPassword() throws -> String { throw Failure.injected }
        func deletePassword() throws { throw Failure.injected }
    }
    private struct Tokens: TonProofTokenService {
        func getWalletToken(_ wallet: Wallet) throws -> String { throw Failure.injected }
        func getWalletsWithMissedToken() -> [Wallet] { [] }
        func loadTokensFor(pairs: [WalletPrivateKeyPair]) async { XCTFail("Enrollment touched classic token service") }
    }
    private struct Tron: TronBalanceService {
        func loadBalance(address: TronSwift.Address, includingTransferFees: Bool) async throws -> TronBalance { throw Failure.injected }
    }
    private final class Fixture {
        let base: URL, record: TOSQuantumCreationRecord, store: WalletsStore, mnemonics = Mnemonics()
        var roles = [TOSQuantumRole](), checkpoints = [UUID](), rejectRescue = false
        lazy var controller = makeController(store)
        func makeController(_ store: WalletsStore) -> WalletAddController {
            WalletAddController(walletsStore: store, tonProofTokenService: Tokens(),
            mnemonicsRepositoty: mnemonics, tronBalanceService: Tron(), networkIdentityProvider: { _ in throw Failure.injected },
            enrollmentDirectory: base, removeEnrollmentRole: { [unowned self] id, role in
                XCTAssertEqual(id, self.record.id); self.roles.append(role)
                if self.rejectRescue && role == .rescue { throw Failure.injected }
            }, removeEnrollmentCheckpoint: { [unowned self] in self.checkpoints.append($0) })
        }
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let profile = try TOSQuantumNetworkProfile(globalID: 1, rootHash: String(repeating: "42", count: 32), fileHash: String(repeating: "43", count: 32))
            let authority = try TOSQuantumSelfPayAuthority(globalID: 1, namespace: Data(repeating: 0x42, count: 32),
                primaryKey: Data(repeating: 1, count: 1312), rescueKey: Data(repeating: 2, count: 32))
            record = try TOSQuantumCreationRecord(id: UUID(), profile: profile,
                identity: TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: authority)))
            store = WalletsStore(keeperInfoStore: KeeperInfoStore(keeperInfoRepository:
                FileSystemVault<KeeperInfo, String>(fileManager: .default, directory: base.appendingPathComponent("main"))))
            try record.save(baseDirectory: base)
        }
        deinit { try? FileManager.default.removeItem(at: base) }
        var meta: WalletMetaData { WalletMetaData(label: "Quantum", tintColor: .defaultColor, icon: .icon(.wallet)) }
    }

    func testCorruptAndPartialEntriesDoNotBlockNewWalletOrAnotherJournalClose() throws {
        let f = try Fixture(), directory = f.base.appendingPathComponent("quantum-creation")
        try Data("partial staging".utf8).write(to: directory.appendingPathComponent(".qcreation-orphan.tmp"))
        try Data("truncated record".utf8).write(to: directory.appendingPathComponent(UUID().uuidString + ".json"))
        let entries = try f.controller.pendingQuantumEnrollments()
        XCTAssertEqual(entries.count, 3); XCTAssertEqual(entries.filter { $0.record == nil }.count, 2)
        let another = try TOSQuantumCreationRecord(id: UUID(), profile: f.record.profile, identity: f.record.identity)
        try another.save(baseDirectory: f.base)
        let file = directory.appendingPathComponent(f.record.id.uuidString + ".json")
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        try f.record.markPublished(baseDirectory: f.base)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(before["identity"] as? String, after["identity"] as? String)
        XCTAssertTrue(try TOSQuantumCreationRecord.load(id: f.record.id, baseDirectory: f.base).published)
        XCTAssertFalse(try TOSQuantumCreationRecord.load(id: another.id, baseDirectory: f.base).published)
    }

    func testScopedDiscardFreesCapacityAndPreservesUnrelatedRecords() async throws {
        let f = try Fixture()
        for _ in 1..<64 { try TOSQuantumCreationRecord(id: UUID(), profile: f.record.profile, identity: f.record.identity).save(baseDirectory: f.base) }
        let candidate = try TOSQuantumCreationRecord(id: UUID(), profile: f.record.profile, identity: f.record.identity)
        XCTAssertThrowsError(try candidate.save(baseDirectory: f.base))
        let entry = try XCTUnwrap(f.controller.pendingQuantumEnrollments().first { $0.id == f.record.id })
        f.mnemonics.valid = false
        do { try await f.controller.discardQuantumEnrollment(entry, passcode: "wrong"); XCTFail("Invalid password discarded enrollment") }
        catch TOSPQError.keyBinding {}
        XCTAssertTrue(f.roles.isEmpty); XCTAssertTrue(f.mnemonics.removed.isEmpty)
        f.mnemonics.valid = true; f.rejectRescue = true
        do { try await f.controller.discardQuantumEnrollment(entry, passcode: "valid"); XCTFail("Custody failure was lost") }
        catch Failure.injected {}
        XCTAssertTrue(f.mnemonics.removed.isEmpty)
        XCTAssertEqual(try TOSQuantumCreationRecord.loadAll(baseDirectory: f.base).count, 64)
        f.rejectRescue = false
        try await f.controller.discardQuantumEnrollment(entry, passcode: "valid")
        XCTAssertEqual(f.mnemonics.removed, [f.record.id.uuidString]); XCTAssertEqual(f.checkpoints, [f.record.id])
        try candidate.save(baseDirectory: f.base)
        XCTAssertEqual(try TOSQuantumCreationRecord.loadAll(baseDirectory: f.base).count, 64)
        XCTAssertFalse(try TOSQuantumCreationRecord.loadAll(baseDirectory: f.base).contains { $0.id == f.record.id })
    }

    func testDamagedOrNoVaultDiscardNeverGuessesPrivateMaterial() async throws {
        let f = try Fixture(), directory = f.base.appendingPathComponent("quantum-creation")
        let corruptID = UUID()
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent(corruptID.uuidString + ".json"))
        let corrupt = try XCTUnwrap(f.controller.pendingQuantumEnrollments().first { $0.id == corruptID })
        try await f.controller.discardQuantumEnrollment(corrupt, passcode: "valid")
        XCTAssertTrue(f.roles.isEmpty); XCTAssertTrue(f.mnemonics.removed.isEmpty); XCTAssertTrue(f.checkpoints.isEmpty)
        f.mnemonics.hasVault = false; f.mnemonics.valid = false
        let entry = try XCTUnwrap(f.controller.pendingQuantumEnrollments().first { $0.id == f.record.id })
        try await f.controller.discardQuantumEnrollment(entry, passcode: "new-installation")
        XCTAssertTrue(f.roles.isEmpty); XCTAssertTrue(f.mnemonics.removed.isEmpty); XCTAssertTrue(f.checkpoints.isEmpty)
        XCTAssertTrue(try TOSQuantumCreationRecord.scan(baseDirectory: f.base).entries.isEmpty)
    }

    func testResumeWithoutConfirmedBackupRefusesBeforeMnemonicOrRegistryWrites() async throws {
        let f = try Fixture()
        let file = f.base.appendingPathComponent("quantum-creation/\(f.record.id.uuidString).json")
        let before = try Data(contentsOf: file)
        do {
            try await f.controller.resumeQuantumCreation(id: f.record.id, metaData: f.meta, passcode: "valid")
            XCTFail("Unconfirmed backup reached recovery")
        } catch TOSPQError.invalidInput {}
        XCTAssertEqual(f.mnemonics.reads, 0)
        XCTAssertTrue(f.roles.isEmpty)
        XCTAssertTrue(f.store.wallets.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testPublishedAndRegisteredEnrollmentsCannotReenterRecoveryOrDiscardActiveCustody() async throws {
        let f = try Fixture()
        try f.record.markPublished(baseDirectory: f.base)
        do { try await f.controller.resumeQuantumCreation(id: f.record.id, metaData: f.meta, passcode: "valid",
            setupSettings: WalletSetupSettings(backupDate: Date(timeIntervalSince1970: 1))); XCTFail("Published record reentered enrollment") }
        catch TOSPQError.keyBinding {}
        XCTAssertEqual(f.mnemonics.reads, 0)
        let entry = try XCTUnwrap(f.controller.pendingQuantumEnrollments().first)
        let wallet = Wallet(id: f.record.id.uuidString,
            identity: WalletIdentity(network: .mainnet, kind: .Quantum(f.record.identity), networkGlobalId: 1),
            metaData: f.meta, setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
        try await f.store.addWallets([wallet])
        XCTAssertTrue(try f.controller.pendingQuantumEnrollments().isEmpty)
        do { try await f.controller.discardQuantumEnrollment(entry, passcode: "valid"); XCTFail("Active wallet custody discarded") }
        catch TOSPQError.keyBinding {}
        XCTAssertTrue(f.roles.isEmpty); XCTAssertTrue(f.mnemonics.removed.isEmpty)
    }
    func testUnreadablePersistedRegistryCannotAuthorizeDiscardFromAnEmptyCache() async throws {
        let f = try Fixture()
        try f.record.markPublished(baseDirectory: f.base)
        let entry = try XCTUnwrap(TOSQuantumCreationRecord.scan(baseDirectory: f.base).entries.first)
        let wallet = Wallet(id: f.record.id.uuidString.lowercased(),
            identity: WalletIdentity(network: .mainnet, kind: .Quantum(f.record.identity), networkGlobalId: 1),
            metaData: f.meta, setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
        try await f.store.addWallets([wallet])
        let file = f.base.appendingPathComponent("main/KeeperInfo/KeeperInfo")
        let valid = try Data(contentsOf: file)
        try Data("PUBLIC CORRUPT REGISTRY".utf8).write(to: file)
        let reopened = WalletsStore(keeperInfoStore: KeeperInfoStore(keeperInfoRepository:
            FileSystemVault<KeeperInfo, String>(fileManager: .default, directory: f.base.appendingPathComponent("main"))))
        XCTAssertTrue(reopened.wallets.isEmpty, "Reproduce the unsafe empty-cache precondition")
        let controller = f.makeController(reopened)
        XCTAssertThrowsError(try controller.pendingQuantumEnrollments())
        do { try await controller.discardQuantumEnrollment(entry, passcode: "valid"); XCTFail("Unreadable registry authorized cleanup") }
        catch FileSystemVault<KeeperInfo, String>.LoadError.corruptedData {}
        catch { XCTFail("Unexpected refusal: \(error)") }
        XCTAssertTrue(f.roles.isEmpty); XCTAssertTrue(f.mnemonics.removed.isEmpty); XCTAssertTrue(f.checkpoints.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("quantum-creation/\(f.record.id.uuidString).json").path))
        try valid.write(to: file)
        XCTAssertTrue(try controller.pendingQuantumEnrollments().isEmpty, "Persisted registry wins over an empty cache")
        do { try await controller.discardQuantumEnrollment(entry, passcode: "valid"); XCTFail("Saved wallet authorized cleanup") }
        catch TOSPQError.keyBinding {}
        catch { XCTFail("Unexpected refusal: \(error)") }
        XCTAssertTrue(f.roles.isEmpty); XCTAssertTrue(f.mnemonics.removed.isEmpty)
    }

    func testSettingsUpdateCannotEraseUnreadableRegistryAndAuthorizePrivateCleanup() async throws {
        for preloadCache in [false, true] {
            let f = try Fixture()
            let entry = try XCTUnwrap(TOSQuantumCreationRecord.scan(baseDirectory: f.base).entries.first)
            let wallet = Wallet(id: f.record.id.uuidString,
                identity: WalletIdentity(network: .mainnet, kind: .Quantum(f.record.identity), networkGlobalId: 1),
                metaData: f.meta, setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
            try await f.store.addWallets([wallet])
            let repository = FileSystemVault<KeeperInfo, String>(fileManager: .default, directory: f.base.appendingPathComponent("main"))
            let keeper = KeeperInfoStore(keeperInfoRepository: repository)
            if preloadCache { XCTAssertNotNil(keeper.state) }
            let file = f.base.appendingPathComponent("main/KeeperInfo/KeeperInfo")
            let damaged = Data("PUBLIC CORRUPT REGISTRY".utf8)
            try damaged.write(to: file)
            if !preloadCache { XCTAssertNil(keeper.state) }
            let settings = AppSettingsStore(keeperInfoStore: keeper)
            let completed = expectation(description: "Settings update completes even on failed persistence")
            settings.toggleIsSecureMode { _ in completed.fulfill() }
            await fulfillment(of: [completed], timeout: 2)
            XCTAssertEqual(try? Data(contentsOf: file), damaged, "A settings update must preserve an unreadable registry")
            let controller = f.makeController(WalletsStore(keeperInfoStore: keeper))
            XCTAssertThrowsError(try controller.pendingQuantumEnrollments())
            do { try await controller.discardQuantumEnrollment(entry, passcode: "valid"); XCTFail("Settings update authorized private cleanup") }
            catch FileSystemVault<KeeperInfo, String>.LoadError.corruptedData {}
            catch { XCTFail("Unexpected refusal: \(error)") }
            XCTAssertTrue(f.roles.isEmpty); XCTAssertTrue(f.mnemonics.removed.isEmpty); XCTAssertTrue(f.checkpoints.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.base.appendingPathComponent("quantum-creation/\(f.record.id.uuidString).json").path))
        }
    }

    func testPublishedOrphanCleanupIsPublicOnlyEvenWithAnUnavailableVault() async throws {
        let f = try Fixture()
        try f.record.markPublished(baseDirectory: f.base)
        let entry = try XCTUnwrap(f.controller.pendingQuantumEnrollments().first)
        f.mnemonics.valid = false
        try await f.controller.discardQuantumEnrollment(entry, passcode: "not-used-for-public-cleanup")
        XCTAssertTrue(f.roles.isEmpty); XCTAssertTrue(f.mnemonics.removed.isEmpty); XCTAssertTrue(f.checkpoints.isEmpty)
        XCTAssertEqual(f.mnemonics.checks, 0)
        XCTAssertTrue(try TOSQuantumCreationRecord.scan(baseDirectory: f.base).entries.isEmpty)
    }

    func testResumeRejectsConflictingSavedIdentityBeforeReadingMnemonic() async throws {
        for sameUUID in [true, false] {
            let f = try Fixture()
            let kind: WalletKind = sameUUID
                ? .Regular(TonSwift.PublicKey(data: Data(repeating: 7, count: 32)), .v4R2)
                : .Quantum(f.record.identity)
            let saved = Wallet(id: sameUUID ? f.record.id.uuidString.lowercased() : UUID().uuidString,
                identity: WalletIdentity(network: .mainnet, kind: kind, networkGlobalId: 1),
                metaData: f.meta, setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
            try await f.store.addWallets([saved])
            do { try await f.controller.resumeQuantumCreation(id: f.record.id, metaData: f.meta, passcode: "valid",
                setupSettings: WalletSetupSettings(backupDate: Date(timeIntervalSince1970: 1))); XCTFail("Saved identity conflict reached recovery") }
            catch TOSPQError.keyBinding {}
            XCTAssertEqual(f.mnemonics.reads, 0); XCTAssertTrue(f.roles.isEmpty)
        }
    }

}
