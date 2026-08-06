import Foundation

public final class KnownAccountsAssembly {
    private let toswalletApiAssembly: TosWalletAPIAssembly
    private let coreAssembly: CoreAssembly

    init(
        toswalletApiAssembly: TosWalletAPIAssembly,
        coreAssembly: CoreAssembly
    ) {
        self.toswalletApiAssembly = toswalletApiAssembly
        self.coreAssembly = coreAssembly
    }

    private weak var _knownAccountsProvider: KnownAccountsProvider?
    public var knownAccountsProvider: KnownAccountsProvider {
        if let knownAccountsProvider = _knownAccountsProvider {
            return knownAccountsProvider
        } else {
            let knownAccountsProvider = KnownAccountsProvider(knownAccountsService: knownAccountsService())
            _knownAccountsProvider = knownAccountsProvider
            return knownAccountsProvider
        }
    }

    func knownAccountsService() -> KnownAccountsService {
        KnownAccountsServiceImplementation(
            session: .shared,
            knownAccountsRepository: knownAccountsRepository()
        )
    }

    func knownAccountsRepository() -> KnownAccountsRepository {
        KnownAccountsRepositoryImplementation(fileSystemVault: coreAssembly.fileSystemVault())
    }
}
