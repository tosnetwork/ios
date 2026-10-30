import CoreComponents
@testable import KeeperCore
import TonSwift
import XCTest

final class QuantumWalletModelTests: XCTestCase {
    private func birth() throws -> TOSQuantumSelfPayIdentity {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tos-quantum-self-pay", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let encoded = try XCTUnwrap(object["identity_boc"] as? String)
        return try TOSQuantumSelfPayIdentity(boc: XCTUnwrap(Data(base64Encoded: encoded)))
    }

    private func wallet(_ identity: WalletIdentity, id: String = "public-model-test") -> Wallet {
        Wallet(id: id, identity: identity,
               metaData: WalletMetaData(label: "Quantum", tintColor: .defaultColor, icon: .icon(.wallet)),
               setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
    }

    func testQuantumWalletPersistsWholeBirthIdentityWithoutAClassicPublicKey() throws {
        let birth = try birth(), identity = WalletIdentity(network: .testnet, kind: .Quantum(birth))
        let original = wallet(identity)
        let data = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(object["identity"] as? String).hasPrefix("qsp1:"),
                      "Quantum identity must persist its complete reference tree")
        let restored = try JSONDecoder().decode(Wallet.self, from: data)
        XCTAssertEqual(restored.identity, identity)
        XCTAssertEqual(try restored.identity.identifier(), try identity.identifier())
        XCTAssertEqual(try restored.address, birth.address)
        XCTAssertEqual(restored.kind, .quantum)
        XCTAssertEqual(try Builder().store(restored.stateInit).endCell().hash(), birth.wallet.stateInit.hash())
        XCTAssertEqual(try restored.quantumWallet.initialData.hash(), birth.wallet.initialData.hash())
        XCTAssertThrowsError(try restored.publicKey)
        XCTAssertThrowsError(try restored.contract)
        XCTAssertThrowsError(try restored.contractVersion)
        XCTAssertFalse(restored.isTonconnectAvailable)
        XCTAssertFalse(restored.isBatteryEnable)
        XCTAssertTrue(restored.isReceiveEnable)
        XCTAssertFalse(restored.isBackupAvailable)
        XCTAssertFalse(restored.isSendAvailable)
        XCTAssertFalse(restored.isSendEnable)
        XCTAssertFalse(restored.isScanEnable)
    }

    func testMainWalletStoreReloadsQuantumFromRealFileRepository() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileSystemVault<KeeperInfo, String>(fileManager: .default, directory: directory)
        let original = wallet(WalletIdentity(network: .mainnet, kind: .Quantum(try birth())))
        let store = WalletsStore(keeperInfoStore: KeeperInfoStore(keeperInfoRepository: repository))
        _ = try await store.addWallets([original])
        // A fresh repository/store must read the descriptor from disk, not reuse
        // the in-memory WalletsStore state after its asynchronous mutation.
        let reopened = FileSystemVault<KeeperInfo, String>(fileManager: .default, directory: directory)
        let persisted = try reopened.getKeeperInfo()
        XCTAssertEqual(persisted.wallets.count, 1)
        XCTAssertEqual(persisted.currentWallet.identity, original.identity)
        let restarted = WalletsStore(keeperInfoStore: KeeperInfoStore(keeperInfoRepository: reopened))
        XCTAssertEqual(try restarted.activeWallet.address, try original.address)
        XCTAssertEqual(try restarted.activeWallet.identity.identifier(), try original.identity.identifier())
    }

    func testFailedDurableDeletionPreservesWalletsAndEventsUntilRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try FailingWalletFileRepository(directory: directory)
        let store = WalletsStore(keeperInfoStore: KeeperInfoStore(keeperInfoRepository: repository))
        let quantum = wallet(WalletIdentity(network: .mainnet, kind: .Quantum(try birth())))
        let classic = wallet(WalletIdentity(network: .mainnet,
            kind: .Regular(TonSwift.PublicKey(data: Data(repeating: 7, count: 32)), .v4R2)), id: "retained")
        try await store.addWallets([quantum, classic])
        let observer = WalletPublicationProbe()
        store.addObserver(observer) { probe, _ in probe.record() }
        repository.rejectSaves = true
        do { try await store.deleteWalletDurably(quantum); XCTFail("Real failed file write reported successful deletion") }
        catch FileSystemVault<KeeperInfo, String>.SaveError.other {}
        await drain(store)
        XCTAssertEqual(observer.count, 0); XCTAssertEqual(store.wallets.map(\.id), [quantum.id, classic.id])
        XCTAssertEqual(try repository.getKeeperInfo().wallets.map(\.id), [quantum.id, classic.id])
        repository.rejectSaves = false
        try await store.deleteWalletDurably(quantum)
        await drain(store)
        XCTAssertEqual(observer.count, 2); XCTAssertEqual(store.wallets.map(\.id), [classic.id])
        let file = directory.appendingPathComponent("KeeperInfo/KeeperInfo")
        let valid = try Data(contentsOf: file)
        try Data("corrupt public registry".utf8).write(to: file)
        do { try await store.deleteAllWalletsDurably(); XCTFail("Corrupt registry authorized publishing empty state") }
        catch FileSystemVault<KeeperInfo, String>.LoadError.corruptedData {}
        await drain(store)
        XCTAssertEqual(observer.count, 2); XCTAssertEqual(store.wallets.map(\.id), [classic.id])
        try valid.write(to: file)
        try await store.deleteAllWalletsDurably()
        await drain(store)
        XCTAssertEqual(observer.count, 3); XCTAssertTrue(store.wallets.isEmpty)
        XCTAssertNil(try repository.getKeeperInfoIfPresent())
    }

    func testFailedFileSaveCannotPublishQuantumWalletAndRetryPersistsIt() async throws {
        for hasExistingWallet in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = try FailingWalletFileRepository(directory: directory)
            let keeper = KeeperInfoStore(keeperInfoRepository: repository)
            let store = WalletsStore(keeperInfoStore: keeper)
            let existing = wallet(WalletIdentity(network: .mainnet,
                kind: .Regular(TonSwift.PublicKey(data: Data(repeating: 7, count: 32)), .v4R2)), id: "existing")
            if hasExistingWallet { try await store.addWallets([existing]) }
            let observer = WalletPublicationProbe()
            store.addObserver(observer) { probe, _ in probe.record() }
            let candidate = wallet(WalletIdentity(network: .mainnet, kind: .Quantum(try birth())))
            repository.rejectSaves = true
            do {
                try await store.addWallets([candidate])
                XCTFail("A real file write failure must fail wallet creation")
            } catch FileSystemVault<KeeperInfo, String>.SaveError.other {
                // The filesystem rejects atomic replacement of a directory by a file.
            }
            await drain(store)
            XCTAssertEqual(repository.failedFileWrites, 1)
            XCTAssertEqual(observer.count, 0, "Failed persistence must not publish wallet-added or active-wallet events")
            XCTAssertEqual(store.wallets.map(\.id), hasExistingWallet ? [existing.id] : [])
            XCTAssertEqual(keeper.state?.wallets.map(\.id) ?? [], hasExistingWallet ? [existing.id] : [])
            XCTAssertEqual(try repository.getKeeperInfoIfPresent()?.wallets.map(\.id) ?? [], hasExistingWallet ? [existing.id] : [])

            repository.rejectSaves = false
            try await store.addWallets([candidate])
            await drain(store)
            XCTAssertEqual(observer.count, 2)
            let reopened = FileSystemVault<KeeperInfo, String>(fileManager: .default, directory: directory)
            let persisted = try reopened.getKeeperInfo()
            XCTAssertEqual(try persisted.currentWallet.address, try candidate.address)
            XCTAssertEqual(persisted.wallets.count, hasExistingWallet ? 2 : 1)
        }
    }

    func testUnreadableRegistryIsNotOverwrittenAsAnEmptyWalletList() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("KeeperInfo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("KeeperInfo")
        let corrupted = Data("not a wallet registry".utf8)
        try corrupted.write(to: file)
        let repository = FileSystemVault<KeeperInfo, String>(fileManager: .default, directory: directory)
        let store = WalletsStore(keeperInfoStore: KeeperInfoStore(keeperInfoRepository: repository))
        // The old display API returns an empty state after a read failure. That
        // must not turn the failure into permission to overwrite the file.
        XCTAssertTrue(store.wallets.isEmpty)
        let candidate = wallet(WalletIdentity(network: .mainnet, kind: .Quantum(try birth())))
        do {
            try await store.addWallets([candidate])
            XCTFail("A corrupt registry must fail creation before saving")
        } catch FileSystemVault<KeeperInfo, String>.LoadError.corruptedData {
        }
        XCTAssertEqual(try Data(contentsOf: file), corrupted)
        XCTAssertTrue(store.wallets.isEmpty)
    }

    func testEmptyAddCompletesAndDoesNotWriteARegistry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileSystemVault<KeeperInfo, String>(fileManager: .default, directory: directory)
        let store = WalletsStore(keeperInfoStore: KeeperInfoStore(keeperInfoRepository: repository))
        let completed = expectation(description: "Empty addition completes")
        store.addWallets([]) { result in
            switch result {
            case let .success(state): XCTAssertTrue(state.wallets.isEmpty)
            case let .failure(error): XCTFail("Unexpected failure: \(error)")
            }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertNil(try repository.getKeeperInfoIfPresent())
    }

    private func drain(_ store: WalletsStore) async {
        await withCheckedContinuation { continuation in
            store.updateState({ _ in nil }) { _ in continuation.resume() }
        }
    }

    func testClassicalIdentitiesKeepTheirStoredEncodingAddressAndIdentifier() throws {
        let key = TonSwift.PublicKey(data: Data(repeating: 7, count: 32))
        // Frozen storage layout from pre-Quantum 48ecb5b: testnet int16,
        // Regular tag 0/5, Ed25519 bytes, revision/4, optional TOS global ID/32.
        let revisions: [(WalletContractVersion, String)] = [(.v3R1, "0001"), (.v3R2, "0010"),
            (.v4R1, "0011"), (.v4R2, "0100"), (.v5Beta, "0101"), (.v5R1, "0110"), (.tosV5R1, "0111")]
        for (version, tag) in revisions {
            let original = wallet(WalletIdentity(network: .testnet, kind: .Regular(key, version),
                networkGlobalId: version == .tosV5R1 ? 42 : nil))
            let encoded = try JSONEncoder().encode(original.identity)
            let text = try JSONDecoder().decode(String.self, from: encoded)
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue(text.allSatisfy { $0 == "0" || $0 == "1" })
            let historical = "1111111111111101" + "00000" + String(repeating: "00000111", count: 32)
                + tag + (version == .tosV5R1 ? "00000000000000000000000000101010" : "")
            XCTAssertEqual(text, historical)
            let historicalWallet = wallet(try JSONDecoder().decode(WalletIdentity.self,
                from: JSONEncoder().encode(historical)))
            XCTAssertEqual(try historicalWallet.address, try original.address)
            XCTAssertEqual(try historicalWallet.identity.identifier(), try original.identity.identifier())
            let restored = wallet(try JSONDecoder().decode(WalletIdentity.self, from: encoded))
            XCTAssertEqual(try restored.address, try original.address)
            XCTAssertEqual(try restored.identity.identifier(), try original.identity.identifier())
            XCTAssertEqual(try restored.publicKey, key)
            XCTAssertThrowsError(try restored.quantumWallet)
        }
    }

    func testMalformedQuantumModelAndMixedNetworkIdentityAreRejected() throws {
        let birth = try birth()
        let wrong = WalletIdentity(network: .mainnet, kind: .Quantum(birth), networkGlobalId: 43)
        XCTAssertThrowsError(try JSONEncoder().encode(wrong))
        XCTAssertThrowsError(try wrong.identifier())
        XCTAssertThrowsError(try wallet(wrong).address)
        XCTAssertThrowsError(try wallet(wrong).stateInit)
        let mismatched = try Builder().store(Network.mainnet).store(WalletKind.Quantum(birth)).store(int: 43, bits: 32).endCell()
        let valid = try Builder().store(WalletIdentity(network: .mainnet, kind: .Quantum(birth))).endCell()
        let trailing = try Builder().store(slice: valid.beginParse()).store(bit: false).endCell()
        let classical = try Builder().store(WalletIdentity(network: .mainnet,
            kind: .Regular(TonSwift.PublicKey(data: Data(repeating: 0, count: 32)), .v4R2))).endCell()
        for root in [mismatched, trailing, classical] {
            let encoded = try JSONEncoder().encode("qsp1:" + root.toBoc().base64EncodedString())
            XCTAssertThrowsError(try JSONDecoder().decode(WalletIdentity.self, from: encoded))
        }
        let stripped = try JSONEncoder().encode(valid.bits.toBinary())
        XCTAssertThrowsError(try JSONDecoder().decode(WalletIdentity.self, from: stripped))
    }

    func testQuantumMirrorPreservesEveryNetworkSelector() throws {
        for network in [Network.mainnet, .testnet, .tetra] {
            let original = wallet(WalletIdentity(network: network, kind: .Quantum(try birth())))
            let mirror = try JSONEncoder().encode(RNWallet(wallet: original))
            let restored = try JSONDecoder().decode(RNWallet.self, from: mirror).getWallet(backupDate: nil)
            XCTAssertEqual(restored.network, network)
            XCTAssertEqual(restored.identity, original.identity)
            XCTAssertEqual(try restored.identity.identifier(), try original.identity.identifier())
            XCTAssertEqual(try restored.address, try original.address)
        }
    }

    func testMirrorRoundTripCarriesQuantumIdentityAndRejectsMixedClassicFields() throws {
        let original = wallet(WalletIdentity(network: .testnet, kind: .Quantum(try birth())))
        let encoded = try JSONEncoder().encode(RNWallet(wallet: original))
        let restored = try JSONDecoder().decode(RNWallet.self, from: encoded).getWallet(backupDate: nil)
        XCTAssertEqual(restored.identity, original.identity)
        XCTAssertEqual(try restored.address, try original.address)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["pubkey"])
        XCTAssertNotNil(object["quantumIdentity"])
        for (key, value) in [("pubkey", "00"), ("version", "v4R2"), ("type", "Regular"), ("networkGlobalId", 43)] as [(String, Any)] {
            var changed = object; changed[key] = value
            let data = try JSONSerialization.data(withJSONObject: changed)
            XCTAssertThrowsError(try JSONDecoder().decode(RNWallet.self, from: data).getWallet(backupDate: nil))
        }
        object.removeValue(forKey: "quantumIdentity")
        XCTAssertThrowsError(try JSONDecoder().decode(RNWallet.self,
            from: JSONSerialization.data(withJSONObject: object)).getWallet(backupDate: nil))
    }
}

private final class WalletPublicationProbe {
    private let lock = NSLock()
    private var events = 0
    func record() { lock.lock(); defer { lock.unlock() }; events += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return events }
}

private final class FailingWalletFileRepository: KeeperInfoRepository {
    private let repository: FileSystemVault<KeeperInfo, String>
    private let blockedWriter: FileSystemVault<KeeperInfo, String>
    var rejectSaves = false
    private(set) var failedFileWrites = 0

    init(directory: URL) throws {
        repository = FileSystemVault(fileManager: .default, directory: directory)
        let blocked = directory.appendingPathComponent("blocked")
        blockedWriter = FileSystemVault(fileManager: .default, directory: blocked)
        try FileManager.default.createDirectory(at: blocked.appendingPathComponent("KeeperInfo/KeeperInfo"), withIntermediateDirectories: true)
    }
    func getKeeperInfo() throws -> KeeperInfo { try repository.getKeeperInfo() }
    func saveKeeperInfo(_ keeperInfo: KeeperInfo) throws {
        if rejectSaves {
            do { try blockedWriter.saveKeeperInfo(keeperInfo) }
            catch { failedFileWrites += 1; throw error }
        } else {
            try repository.saveKeeperInfo(keeperInfo)
        }
    }
    func removeKeeperInfo() throws { try repository.removeKeeperInfo() }
}
