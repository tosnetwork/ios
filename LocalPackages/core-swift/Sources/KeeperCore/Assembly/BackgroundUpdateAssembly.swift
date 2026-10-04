import Foundation

public final class BackgroundUpdateAssembly {
    private let apiProvider: APIProvider
    private let storesAssembly: StoresAssembly
    private let coreAssembly: CoreAssembly

    init(
        apiProvider: APIProvider,
        storesAssembly: StoresAssembly,
        coreAssembly: CoreAssembly
    ) {
        self.apiProvider = apiProvider
        self.storesAssembly = storesAssembly
        self.coreAssembly = coreAssembly
    }

    private weak var _backgroundUpdate: BackgroundUpdate?
    public var backgroundUpdate: BackgroundUpdate {
        if let backgroundUpdate = _backgroundUpdate {
            return backgroundUpdate
        } else {
            let backgroundUpdate = BackgroundUpdate(
                walletStore: storesAssembly.walletsStore
            ) { [apiProvider] wallet in
                WalletBackgroundUpdate(
                    wallet: wallet,
                    snapshot: {
                        try await apiProvider.api(wallet.network).walletBackgroundUpdateCursor(wallet: wallet)
                    }
                )
            }
            _backgroundUpdate = backgroundUpdate
            return backgroundUpdate
        }
    }
}
