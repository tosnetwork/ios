import Foundation

public final class RootController {
    public enum State {
        case onboarding
        case main(wallets: [Wallet], activeWallet: Wallet)
    }

    private let configuration: Configuration
    private let deeplinkParser: DeeplinkParser
    private let keeperInfoRepository: KeeperInfoRepository
    private let mnemonicsRepository: MnemonicsRepository
    private let knownAccountsProvider: KnownAccountsProvider

    init(
        configuration: Configuration,
        deeplinkParser: DeeplinkParser,
        keeperInfoRepository: KeeperInfoRepository,
        mnemonicsRepository: MnemonicsRepository,
        knownAccountsProvider: KnownAccountsProvider
    ) {
        self.configuration = configuration
        self.deeplinkParser = deeplinkParser
        self.keeperInfoRepository = keeperInfoRepository
        self.mnemonicsRepository = mnemonicsRepository
        self.knownAccountsProvider = knownAccountsProvider
    }

    public func loadConfigurations() {
        knownAccountsProvider.load()
        Task {
            await configuration.loadConfigurations()
        }
    }

    public func parseDeeplink(string: String?) throws -> Deeplink {
        try deeplinkParser.parse(string: string)
    }
}
