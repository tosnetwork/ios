import Foundation

public final class BuySellAssembly {
    private let toswalletApiAssembly: TosWalletAPIAssembly
    private let coreAssembly: CoreAssembly

    init(
        toswalletApiAssembly: TosWalletAPIAssembly,
        coreAssembly: CoreAssembly
    ) {
        self.toswalletApiAssembly = toswalletApiAssembly
        self.coreAssembly = coreAssembly
    }

    private weak var _buySellProvider: BuySellProvider?
    public var buySellProvider: BuySellProvider {
        if let buySellProvider = _buySellProvider {
            return buySellProvider
        } else {
            let buySellProvider = BuySellProvider(buySellMethodsService: buySellMethodsService())
            _buySellProvider = buySellProvider
            return buySellProvider
        }
    }

    public func buySellMethodsService() -> BuySellMethodsService {
        BuySellMethodsServiceImplementation(
            api: toswalletApiAssembly.api,
            buySellMethodsRepository: buySellMethodsRepository()
        )
    }

    func buySellMethodsRepository() -> BuySellMethodsRepository {
        BuySellMethodsRepositoryImplementation(fileSystemVault: coreAssembly.fileSystemVault())
    }
}
