import CoreComponents
import Foundation
import BigInt
import TonSwift
import TonTransport

public struct ActiveWalletModel: Identifiable {
    public let id: String
    public let revision: WalletContractVersion
    public let address: Address
    public let isActive: Bool
    public let balance: Balance
    public let nfts: [NFT]
    public let isAdded: Bool
    public let assetDiscoveryComplete: Bool
    public let hasIndexedAssets: Bool
    public let accountStateKnown: Bool

    public init(
        id: String,
        revision: WalletContractVersion,
        address: Address,
        isActive: Bool,
        balance: Balance,
        nfts: [NFT],
        isAdded: Bool = false,
        assetDiscoveryComplete: Bool = true,
        hasIndexedAssets: Bool = false,
        accountStateKnown: Bool = true
    ) {
        self.id = id
        self.revision = revision
        self.address = address
        self.isActive = isActive
        self.balance = balance
        self.nfts = nfts
        self.isAdded = isAdded
        self.assetDiscoveryComplete = assetDiscoveryComplete
        self.hasIndexedAssets = hasIndexedAssets
        self.accountStateKnown = accountStateKnown
    }
}

protocol ActiveWalletsService {
    func loadActiveWallets(
        publicKey: TonSwift.PublicKey,
        network: Network,
        currency: Currency
    ) async throws -> [ActiveWalletModel]
    func loadActiveWallets(
        accounts: [(id: String, address: Address, revision: WalletContractVersion)],
        network: Network,
        currency: Currency
    ) async throws -> [ActiveWalletModel]
}

final class ActiveWalletsServiceImplementation: ActiveWalletsService {
    private let apiProvider: APIProvider
    private let jettonsBalanceService: JettonBalanceService
    private let accountNFTService: AccountNFTService
    private let walletsService: WalletsService

    init(
        apiProvider: APIProvider,
        jettonsBalanceService: JettonBalanceService,
        accountNFTService: AccountNFTService,
        walletsService: WalletsService
    ) {
        self.apiProvider = apiProvider
        self.jettonsBalanceService = jettonsBalanceService
        self.accountNFTService = accountNFTService
        self.walletsService = walletsService
    }

    func loadActiveWalletModel(
        id: String,
        address: Address,
        revision: WalletContractVersion,
        network: Network,
        currency: Currency
    ) async throws -> ActiveWalletModel {
        let client = await apiProvider.api(network).boundTOSRPCClient()
        async let accountTask = client.call(method: "getAddressInformation", params: ["address": address.toRaw()])
        async let hintsTask = client.recoveryAssets(address: address.toRaw())
        let account = try await accountTask
        let hints = try? await hintsTask
        try Task.checkCancellation()
        let state = try TOSRecoveryAccount.parse(account)
        let balance = Balance(tonBalance: TonBalance(amount: state.amount), jettonsBalance: [])
        return ActiveWalletModel(id: id, revision: revision, address: address,
            isActive: state.deployed || !balance.isEmpty || hints?.hasAssets == true,
            balance: balance, nfts: [], assetDiscoveryComplete: hints?.complete == true,
            hasIndexedAssets: hints?.hasAssets == true)
    }

    func loadActiveWallets(
        publicKey: TonSwift.PublicKey,
        network: Network,
        currency: Currency
    ) async throws -> [ActiveWalletModel] {
        let revisions = WalletContractVersion.allCases

        return try await withThrowingTaskGroup(of: ActiveWalletModel.self, returning: [ActiveWalletModel].self) { taskGroup in
            for revision in revisions {
                let address = try createAddress(
                    publicKey: publicKey,
                    revision: revision,
                    networkId: network
                )
                taskGroup.addTask {
                    do {
                        return try await self.loadActiveWalletModel(
                            id: address.toRaw(),
                            address: address,
                            revision: revision,
                            network: network,
                            currency: currency
                        )
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        return ActiveWalletModel(
                            id: address.toRaw(),
                            revision: revision,
                            address: address,
                            isActive: false,
                            balance: Balance(
                                tonBalance: TonBalance(amount: 0),
                                jettonsBalance: []
                            ),
                            nfts: [], assetDiscoveryComplete: false, accountStateKnown: false
                        )
                    }
                }
            }

            var resultModels = [ActiveWalletModel]()
            for try await result in taskGroup { resultModels.append(result) }
            return resultModels
        }
    }

    func loadActiveWallets(
        accounts: [(id: String, address: Address, revision: WalletContractVersion)],
        network: Network,
        currency: Currency
    ) async throws -> [ActiveWalletModel] {
        return try await withThrowingTaskGroup(of: ActiveWalletModel.self, returning: [ActiveWalletModel].self) { taskGroup in
            for account in accounts {
                taskGroup.addTask {
                    do {
                        return try await self.loadActiveWalletModel(
                            id: account.id,
                            address: account.address,
                            revision: account.revision,
                            network: network,
                            currency: currency
                        )
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        return ActiveWalletModel(
                            id: account.id,
                            revision: account.revision,
                            address: account.address,
                            isActive: false,
                            balance: Balance(
                                tonBalance: TonBalance(amount: 0),
                                jettonsBalance: []
                            ),
                            nfts: [], assetDiscoveryComplete: false, accountStateKnown: false
                        )
                    }
                }
            }

            var resultModels = [ActiveWalletModel]()
            for try await result in taskGroup {
                // TODO: refactor
                //        guard result.isActive else {
                //          continue
                //        }
                resultModels.append(result)
            }
            return resultModels
        }
    }
}

private extension ActiveWalletsServiceImplementation {
    func createAddress(publicKey: TonSwift.PublicKey, revision: WalletContractVersion, networkId: Network) throws -> Address {
        let networkRawValue = networkId.walletNetworkGlobalId

        let contract: WalletContract
        switch revision {
        case .tosV5R1:
            // TOS V5 addresses do not encode the network ID. This instance is
            // used only for discovery, never for creating a signing request.
            contract = try TOSWalletV5R1(publicKey: publicKey.data, networkGlobalId: 0)
        case .v5R1:
            contract = WalletV5R1(
                publicKey: publicKey.data,
                walletId: WalletId(networkGlobalId: Int32(networkRawValue), workchain: 0)
            )
        case .v5Beta:
            contract = WalletV5Beta(
                publicKey: publicKey.data,
                walletId: WalletIdBeta(networkGlobalId: Int32(networkRawValue), workchain: 0)
            )
        case .v4R2:
            contract = WalletV4R2(publicKey: publicKey.data)
        case .v4R1:
            contract = WalletV4R1(publicKey: publicKey.data)
        case .v3R2:
            contract = try WalletV3(
                workchain: 0,
                publicKey: publicKey.data,
                revision: .r2
            )
        case .v3R1:
            contract = try WalletV3(
                workchain: 0,
                publicKey: publicKey.data,
                revision: .r1
            )
        }
        return try contract.address()
    }
}
