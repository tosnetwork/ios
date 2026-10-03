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
        if resolvedFormat == .tos { return models.filter { $0.revision == .tosV5R1 } }
        let legacy = models.filter { $0.revision != .tosV5R1 }
        if !legacy.isEmpty { return legacy }
        let contract = WalletV5R1(publicKey: keyPair.publicKey.data, walletId: WalletId(networkGlobalId: Int32(network.walletNetworkGlobalId)))
        let address = try contract.address()
        return [ActiveWalletModel(id: address.toRaw(), revision: .v5R1, address: address, isActive: false, balance: Balance(tonBalance: TonBalance(amount: 0), jettonsBalance: []), nfts: [])]
    }

    public func findActiveWallets(publicKey: TonSwift.PublicKey, network: Network) async throws -> [ActiveWalletModel] {
        let currency = (try? currencyService.getActiveCurrency()) ?? .USD
        return try await activeWalletService.loadActiveWallets(
            publicKey: publicKey,
            network: network,
            currency: currency
        )
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
