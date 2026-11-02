import CoreComponents
import Foundation
import TonSwift
import TonTransport

public final class WalletImportController {
    private let activeWalletService: ActiveWalletsService
    private let currencyService: CurrencyService

    init(
        activeWalletService: ActiveWalletsService,
        currencyService: CurrencyService
    ) {
        self.activeWalletService = activeWalletService
        self.currencyService = currencyService
    }

    public func findActiveWallets(phrase: [String], network: Network, format: WalletMnemonicFormat? = nil) async throws -> [ActiveWalletModel] {
        let mnemonic = try Mnemonic(mnemonicWords: phrase)
        let resolvedFormat = try format ?? WalletMnemonicFormat.detect(words: phrase)
        guard WalletMnemonicFormat.validFormats(words: phrase).contains(resolvedFormat) else { throw WalletMnemonicFormat.Error.invalidPhrase }
        let keyPair = try resolvedFormat.keyPair(words: mnemonic.mnemonicWords)
        let currency = (try? currencyService.getActiveCurrency()) ?? .USD
        let models = try await activeWalletService.loadActiveWallets(
            publicKey: keyPair.publicKey,
            network: network,
            currency: currency
        )
        let family = models.filter { resolvedFormat == .tos ? $0.revision == .tosV5R1 : $0.revision != .tosV5R1 }
        return try ClassicWalletRecovery.select(family, fallback: resolvedFormat == .tos ? .tosV5R1 : .v5R1)
    }

    public func findActiveWallets(publicKey: TonSwift.PublicKey, network: Network) async throws -> [ActiveWalletModel] {
        let currency = (try? currencyService.getActiveCurrency()) ?? .USD
        let models = try await activeWalletService.loadActiveWallets(
            publicKey: publicKey, network: network, currency: currency)
        return try ClassicWalletRecovery.select(models.filter { $0.revision != .tosV5R1 }, fallback: .v5R1)
    }

    public func findActiveWallets(
        accounts: [(id: String, address: Address, revision: WalletContractVersion)],
        network: Network
    ) async throws -> [ActiveWalletModel] {
        let currency = (try? currencyService.getActiveCurrency()) ?? .USD
        return try await activeWalletService.loadActiveWallets(
            accounts: accounts,
            network: network,
            currency: currency
        )
    }
}
