import Foundation
@testable import KeeperCore
import TonSwift
import XCTest

final class BackgroundUpdateLifecycleTests: XCTestCase {
    func testStartBeforeWalletExistsAllowsLaterWalletChangeToStartPolling() async {
        let store = makeStore(wallets: [])
        let firstRead = expectation(description: "New active wallet started polling")
        let probe = LifecycleUpdateProbe { _ in firstRead.fulfill() }
        let background = BackgroundUpdate(walletStore: store, walletBackgroundUpdateProvider: probe.provide)
        defer { background.stop() }
        await drainWalletEvents(store)
        background.start()
        _ = await store.addWallets([fixtureWallet(id: "first")])
        await fulfillment(of: [firstRead], timeout: 2)
        background.stop()
        XCTAssertEqual(probe.snapshotWalletIDs, ["first"])
    }

    func testStoppedWalletChangeCannotRestartPollingButResumeUsesNewWallet() async {
        let firstWallet = fixtureWallet(id: "first")
        let secondWallet = fixtureWallet(id: "second")
        let store = makeStore(wallets: [firstWallet, secondWallet])
        let initial = expectation(description: "First wallet initial read")
        let resumed = expectation(description: "Second wallet resumed read")
        let probe = LifecycleUpdateProbe { wallet in
            if wallet.id == "first" { initial.fulfill() } else { resumed.fulfill() }
        }
        let background = BackgroundUpdate(walletStore: store, walletBackgroundUpdateProvider: probe.provide)
        defer { background.stop() }
        await drainWalletEvents(store)
        background.start()
        await fulfillment(of: [initial], timeout: 2)
        background.stop()
        _ = await store.makeWalletActive(secondWallet)
        await drainWalletEvents(store)
        XCTAssertEqual(probe.snapshotWalletIDs, ["first"])
        XCTAssertEqual(probe.createdWalletIDs, ["first"])
        background.start()
        await fulfillment(of: [resumed], timeout: 2)
        background.stop()
        XCTAssertEqual(probe.snapshotWalletIDs, ["first", "second"])
    }

    func testDeletingAllWalletsStopsPendingReadAndNewWalletCanResume() async {
        let oldWallet = fixtureWallet(id: "deleted")
        let newWallet = fixtureWallet(id: "replacement")
        let store = makeStore(wallets: [oldWallet])
        let initialRead = expectation(description: "Deleted wallet initial read")
        let resumedRead = expectation(description: "Replacement wallet starts polling")
        let deletedWalletRead = expectation(description: "Deleted wallet must not poll again")
        deletedWalletRead.isInverted = true
        let gate = LifecycleCursorReadGate { wallet, index in
            if wallet.id == "deleted" && index == 0 {
                initialRead.fulfill()
            } else if wallet.id == "replacement" {
                resumedRead.fulfill()
            } else {
                deletedWalletRead.fulfill()
            }
        }
        let background = BackgroundUpdate(walletStore: store) { wallet in
            WalletBackgroundUpdate(wallet: wallet, snapshot: { await gate.read(wallet) }, pollIntervalNanoseconds: 2_000_000)
        }
        defer { background.stop() }
        await drainWalletEvents(store)
        background.start()
        await fulfillment(of: [initialRead], timeout: 2)
        _ = await store.deleteAllWallets()
        await drainWalletEvents(store)
        XCTAssertTrue(store.wallets.isEmpty)
        // Releasing a request that ignores cancellation must not resume polling.
        await gate.completePending()
        await fulfillment(of: [deletedWalletRead], timeout: 0.05)
        _ = await store.addWallets([newWallet])
        await fulfillment(of: [resumedRead], timeout: 2)
        background.stop()
        await gate.completePending()
        let readWalletIDs = await gate.walletIDs
        XCTAssertEqual(readWalletIDs, ["deleted", "replacement"])
    }

    func testQueuedPreStopStateAndEventCannotDeliverAfterSameWalletResume() async throws {
        let wallet = fixtureWallet(id: "same")
        let store = makeStore(wallets: [wallet])
        let staleDelivery = expectation(description: "Queued old-generation delivery")
        staleDelivery.isInverted = true
        let probe = LifecycleUpdateProbe { _ in }
        let background = BackgroundUpdate(walletStore: store, walletBackgroundUpdateProvider: probe.provide)
        let observer = LifecycleTestObserver(staleDelivery)
        background.addEventObserver(observer) { observer, _, _ in observer.delivered() }
        background.addStateObserver(observer) { observer, _, _ in observer.delivered() }
        defer { background.stop() }
        await drainWalletEvents(store)
        try await MainActor.run {
            background.start()
            let updater = try XCTUnwrap(probe.updater(for: wallet))
            // Exercise the real asynchronous forwarding closures before stop.
            updater.eventClosure?(BackgroundUpdateEvent(wallet: wallet, lt: 1, txHash: String(repeating: "1", count: 64)))
            updater.stateClosure?(.noConnection)
            background.stop()
            background.start()
        }
        await fulfillment(of: [staleDelivery], timeout: 0.05)
        withExtendedLifetime(observer) {}
    }

    private func drainWalletEvents(_ store: WalletsStore) async {
        // The store barrier runs after its queued events; the main barrier then
        // runs after those events' BackgroundUpdate lifecycle handlers.
        await withCheckedContinuation { continuation in
            store.updateState({ _ in nil }) { _ in
                DispatchQueue.main.async { continuation.resume(returning: ()) }
            }
        }
    }

    private func fixtureWallet(id: String) -> Wallet {
        Wallet(id: id, identity: WalletIdentity(network: .mainnet, kind: .Regular(PublicKey(data: Data(repeating: 0, count: 32)), .tosV5R1), networkGlobalId: 3), metaData: WalletMetaData(label: id, tintColor: .defaultColor, icon: .icon(.wallet)), setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
    }

    private func makeStore(wallets: [Wallet]) -> WalletsStore {
        let keeperInfo = wallets.first.map {
            KeeperInfo(wallets: wallets, currentWallet: $0, currency: .defaultCurrency, securitySettings: SecuritySettings(isBiometryEnabled: false, isLockScreen: false), appSettings: AppSettings(isSecureMode: false, searchEngine: .duckduckgo), country: .auto)
        }
        return WalletsStore(keeperInfoStore: KeeperInfoStore(keeperInfoRepository: LifecycleKeeperInfoRepository(keeperInfo)))
    }
}

private final class LifecycleTestObserver {
    private let expectation: XCTestExpectation
    init(_ expectation: XCTestExpectation) { self.expectation = expectation }
    func delivered() { expectation.fulfill() }
}

private final class LifecycleUpdateProbe {
    private let lock = NSLock()
    private var updaters = [Wallet: WalletBackgroundUpdate]()
    private var snapshots = [String]()
    private var created = [String]()
    private let onSnapshot: (Wallet) -> Void

    init(onSnapshot: @escaping (Wallet) -> Void) { self.onSnapshot = onSnapshot }

    var snapshotWalletIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }

    var createdWalletIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return created
    }

    func updater(for wallet: Wallet) -> WalletBackgroundUpdate? {
        lock.lock()
        defer { lock.unlock() }
        return updaters[wallet]
    }

    func provide(_ wallet: Wallet) -> WalletBackgroundUpdate {
        let updater = WalletBackgroundUpdate(wallet: wallet, snapshot: { [weak self] in
            self?.recordSnapshot(wallet)
            // These lifecycle tests control forwarding directly and make no RPC.
            throw CancellationError()
        }, pollIntervalNanoseconds: 2_000_000)
        lock.lock()
        updaters[wallet] = updater
        created.append(wallet.id)
        lock.unlock()
        return updater
    }

    private func recordSnapshot(_ wallet: Wallet) {
        lock.lock()
        snapshots.append(wallet.id)
        lock.unlock()
        onSnapshot(wallet)
    }
}

private final class LifecycleKeeperInfoRepository: KeeperInfoRepository {
    private var keeperInfo: KeeperInfo?
    init(_ keeperInfo: KeeperInfo?) { self.keeperInfo = keeperInfo }
    func getKeeperInfo() throws -> KeeperInfo {
        guard let keeperInfo else { throw WalletsStore.Error.noWallets }
        return keeperInfo
    }
    func saveKeeperInfo(_ keeperInfo: KeeperInfo) throws { self.keeperInfo = keeperInfo }
    func removeKeeperInfo() throws { keeperInfo = nil }
}

private actor LifecycleCursorReadGate {
    private var continuations = [CheckedContinuation<TOSWalletTransactionCursor, Never>]()
    private(set) var walletIDs = [String]()
    private let onRead: (Wallet, Int) -> Void

    init(onRead: @escaping (Wallet, Int) -> Void) { self.onRead = onRead }

    func read(_ wallet: Wallet) async -> TOSWalletTransactionCursor {
        let index = walletIDs.count
        walletIDs.append(wallet.id)
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
            onRead(wallet, index)
        }
    }

    func completePending() {
        let pending = continuations
        continuations.removeAll()
        let cursor = TOSWalletTransactionCursor(lt: 0, txHash: String(repeating: "0", count: 64))
        pending.forEach { $0.resume(returning: cursor) }
    }
}
