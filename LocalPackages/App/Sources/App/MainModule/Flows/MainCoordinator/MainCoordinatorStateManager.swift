import Foundation
import KeeperCore
import TKFeatureFlags

final class MainCoordinatorStateManager {
    struct State: Equatable {
        enum Tab: Equatable {
            case wallet
            case history
            case browser
            case purchases
        }

        let tabs: [Tab]
    }

    var didUpdateState: ((State) -> Void)?

    private var walletNFTsStore: WalletNFTStore?

    private let walletsStore: WalletsStore
    private let configuration: Configuration
    private let walletNFTStoreProvider: (Wallet) -> WalletNFTStore

    init(
        walletsStore: WalletsStore,
        configuration: Configuration,
        walletNFTStoreProvider: @escaping (Wallet) -> WalletNFTStore
    ) {
        self.walletsStore = walletsStore
        self.configuration = configuration
        self.walletNFTStoreProvider = walletNFTStoreProvider

        walletsStore.addObserver(self) { observer, event in
            switch event {
            case .didChangeActiveWallet:
                DispatchQueue.main.async {
                    observer.updateState()
                }
            default: break
            }
        }
    }

    func getState() throws -> State {
        let wallet = try walletsStore.activeWallet

        let nfts = walletNFTsStore?.state.value.nfts.visible ?? []
        return createState(activeWallet: wallet, nfts: nfts)
    }

    private func createState(activeWallet: Wallet, nfts: [NFT]) -> State {
        State(tabs: [.wallet])
    }

    private func updateState() {
        guard let state = try? getState() else { return }
        didUpdateState?(state)
    }

    private func updateWalletNFTsManagedStore() {
        if let wallet = try? walletsStore.activeWallet {
            self.walletNFTsStore = walletNFTStoreProvider(wallet)
            Task { await self.walletNFTsStore?.addObserver(self) }
        } else {
            self.walletNFTsStore = nil
        }
    }
}

extension MainCoordinatorStateManager: WalletNFTStoreObserver {
    func didUpdateNFTs(_ nfts: WalletNFTs) {
        Task { @MainActor in updateState() }
    }
}
