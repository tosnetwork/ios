import BigInt
import KeeperCore
import TKCoordinator
import TKCore
import TKLocalize
import TKUIKit
import TonSwift
import UIKit

public final class CollectiblesCoordinator: RouterCoordinator<NavigationControllerRouter> {
    var didOpenDapp: ((_ url: URL, _ title: String?) -> Void)?
    var didRequestDeeplinkHandling: ((_ deeplink: Deeplink) -> Void)?
    var didRequestOpenBuySell: ((_ isInternalPurchasing: Bool, _ wallet: Wallet) -> Void)?

    private weak var detailsCoordinator: CollectiblesDetailsCoordinator?
    private weak var registerDNSCoordinator: RegisterDNSCoordinator?
    private weak var manageDNSCoordinator: ManageDNSCoordinator?

    private let coreAssembly: TKCore.CoreAssembly
    private let keeperCoreMainAssembly: KeeperCore.MainAssembly
    private let parentRouter: TabBarControllerRouter?

    public init(
        router: NavigationControllerRouter,
        parentRouter: TabBarControllerRouter?,
        coreAssembly: TKCore.CoreAssembly,
        keeperCoreMainAssembly: KeeperCore.MainAssembly
    ) {
        self.coreAssembly = coreAssembly
        self.keeperCoreMainAssembly = keeperCoreMainAssembly
        self.parentRouter = parentRouter
        super.init(router: router)
        router.rootViewController.tabBarItem.title = TKLocales.Tabs.collectibles
        router.rootViewController.tabBarItem.image = .TKUIKit.Icons.Size28.purchase
    }

    override public func start() {
        openCollectibles()
    }

    public func handleTosWalletDeeplink(deeplink: Deeplink) -> Bool {
        if let detailsCoordinator, detailsCoordinator.handleTosWalletDeeplink(deeplink: deeplink) {
            return true
        }
        if case let .publish(model) = deeplink, let registerDNSCoordinator {
            return registerDNSCoordinator.handleTosWalletPublishDeeplink(sign: model)
        }
        if case let .publish(model) = deeplink, let manageDNSCoordinator {
            return manageDNSCoordinator.handleTosWalletPublishDeeplink(sign: model)
        }
        return false
    }
}

private extension CollectiblesCoordinator {
    func openCollectibles() {
        let module = CollectiblesContainerAssembly.module(keeperCoreMainAssembly: keeperCoreMainAssembly)

        module.output.didChangeWallet = { [weak self, keeperCoreMainAssembly] wallet in
            let listModule = CollectiblesListAssembly.module(
                wallet: wallet,
                keeperCoreMainAssembly: keeperCoreMainAssembly
            )

            listModule.output.didSelectNFT = { nft, wallet in
                self?.openNFTDetails(wallet: wallet, nft: nft)
            }

            let collectiblesModule = CollectiblesAssembly.module(
                wallet: wallet,
                collectiblesListViewController: listModule.view,
                keeperCoreMainAssembly: keeperCoreMainAssembly
            )

            collectiblesModule.output.didTapCollectiblesSettings = { [weak self] isSpam in
                guard let self else {
                    return
                }
                self.openPurchases(wallet: wallet, isSpam: isSpam)
            }

            collectiblesModule.output.didTapRegisterDomain = { [weak self] in
                self?.promptDomainAction(wallet: wallet)
            }

            module.view.collectiblesViewController = collectiblesModule.view
        }
        router.push(viewController: module.view, animated: false)
    }

    func openNFTDetails(wallet: Wallet, nft: NFT) {
        guard let wallet = keeperCoreMainAssembly.storesAssembly.walletsStore.getWallet(id: wallet.id) else { return }
        let navigationController = TKNavigationController()
        navigationController.setNavigationBarHidden(true, animated: false)

        let coordinator = CollectiblesDetailsCoordinator(
            router: NavigationControllerRouter(rootViewController: navigationController),
            nft: nft,
            wallet: wallet,
            coreAssembly: coreAssembly,
            keeperCoreMainAssembly: keeperCoreMainAssembly
        )

        coordinator.didOpenDapp = { [weak self] url, title in
            self?.didOpenDapp?(url, title)
        }

        coordinator.didClose = { [weak self, weak coordinator, weak navigationController] in
            navigationController?.dismiss(animated: true)
            guard let coordinator else { return }
            self?.removeChild(coordinator)
        }

        coordinator.didRequestDeeplinkHandling = { [weak self] deeplink in
            self?.didRequestDeeplinkHandling?(deeplink)
        }

        coordinator.didRequestOpenBuySell = { [weak self] isInternalPurchasing in
            self?.didRequestOpenBuySell?(isInternalPurchasing, wallet)
        }

        self.detailsCoordinator = coordinator

        coordinator.start()
        addChild(coordinator)

        router.present(navigationController, onDismiss: { [weak self, weak coordinator] in
            guard let coordinator else { return }
            self?.removeChild(coordinator)
        })
    }

    func openPurchases(wallet: Wallet, isSpam: Bool) {
        guard let wallet = keeperCoreMainAssembly.storesAssembly.walletsStore.getWallet(id: wallet.id) else { return }
        let module = SettingsPurchasesAssembly.module(
            wallet: wallet,
            mode: isSpam ? .spam : .all,
            keeperCoreMainAssembly: keeperCoreMainAssembly
        )

        module.view.setupBackButton()
        guard let navigationController = parentRouter?.rootViewController.navigationController else {
            router.push(viewController: module.view)
            return
        }

        module.output.didOpenTonviewer = { [weak self] url in
            self?.didOpenDapp?(url, "Tonviewer")
        }

        navigationController.pushViewController(module.view, animated: true)
    }

    func promptDomainRegistration(wallet: Wallet) {
        let alert = UIAlertController(
            title: "Register .tos domain",
            message: "Registration opens a public auction at the current on-chain minimum. The exact lowercase name, network, destination and amount are shown again before signing.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "alice.tos"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: TKLocales.Actions.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: TKLocales.Actions.continueAction, style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text, !name.isEmpty else { return }
            Task { await self.inspectDomainRegistration(wallet: wallet, name: name) }
        })
        router.rootViewController.present(alert, animated: true)
    }

    @MainActor
    func inspectDomainRegistration(wallet: Wallet, name: String) async {
        do {
            let state = try await keeperCoreMainAssembly.servicesAssembly.dnsService()
                .inspectDomain(name, network: wallet.network)
            guard state.canonicalName == name, state.lifecycle == .available else {
                throw TOSDNSManagementError.actionNotAllowed
            }
            let now = UInt64(Date().timeIntervalSince1970)
            guard now > TOSDNSAuctionRules.auctionStartTime else {
                throw TOSDNSManagementError.actionNotAllowed
            }
            let amount = try TOSDNSAuctionRules.minimumPrice(labelBytes: state.label.utf8.count, now: now)
            let age = now >= state.observedAt ? now - state.observedAt : 0
            let network = wallet.network == .testnet ? "testnet" : "mainnet"
            let confirmation = UIAlertController(
                title: "Register .tos domain",
                message: "Domain: \(state.canonicalName)\nNetwork: \(network)\nCollection: \(state.collectionAddress.toRaw())\nOpening bid: \(formatTOS(amount)) TOS\nCheckpoint: \(state.masterchainSequence) (\(age)s old)\n\nAvailability and price are checked again before signing.",
                preferredStyle: .alert
            )
            confirmation.addAction(UIAlertAction(title: TKLocales.Actions.cancel, style: .cancel))
            confirmation.addAction(UIAlertAction(title: TKLocales.Actions.continueAction, style: .default) { [weak self] _ in
                self?.openDomainRegistration(wallet: wallet, name: name)
            })
            router.rootViewController.present(confirmation, animated: true)
        } catch {
            ToastPresenter.showToast(configuration: .init(title: "Domain is unavailable or chain state could not be verified."))
        }
    }

    func promptDomainAction(wallet: Wallet) {
        let alert = UIAlertController(
            title: ".tos domains",
            message: "Register a new name or recover an auction that is not yet in your Collectibles list.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Register new domain", style: .default) { [weak self] _ in
            self?.promptDomainRegistration(wallet: wallet)
        })
        alert.addAction(UIAlertAction(title: "Manage public auction", style: .default) { [weak self] _ in
            self?.promptDomainManagement(wallet: wallet)
        })
        alert.addAction(UIAlertAction(title: TKLocales.Actions.cancel, style: .cancel))
        router.rootViewController.present(alert, animated: true)
    }

    func promptDomainManagement(wallet: Wallet) {
        let alert = UIAlertController(
            title: "Manage .tos auction",
            message: "Enter the exact lowercase second-level name. The wallet will only offer a valid bid, finalization, or release/re-auction.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "alice.tos"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: TKLocales.Actions.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: TKLocales.Actions.continueAction, style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text, !name.isEmpty else { return }
            Task { await self.inspectDomainManagement(wallet: wallet, name: name) }
        })
        router.rootViewController.present(alert, animated: true)
    }

    @MainActor
    func inspectDomainManagement(wallet: Wallet, name: String) async {
        do {
            let state = try await keeperCoreMainAssembly.servicesAssembly.dnsService()
                .inspectDomain(name, network: wallet.network)
            guard state.canonicalName == name else { throw TOSDNSManagementError.actionNotAllowed }
            let now = UInt64(Date().timeIntervalSince1970)
            let action: TOSDNSManagementAction
            let actionTitle: String
            let amount: BigUInt
            switch state.lifecycle {
            case .auction:
                action = .bid(amount: TOSDNSAuctionRules.minimumNextBid(state.maximumBid))
                actionTitle = "Place minimum valid bid"
                amount = TOSDNSAuctionRules.minimumNextBid(state.maximumBid)
            case .auctionEnded:
                action = .finishAuction
                actionTitle = "Finalize auction"
                amount = TOSDNSAuctionRules.contractActionValue
            case .releasable:
                amount = try TOSDNSAuctionRules.minimumPrice(labelBytes: state.label.utf8.count, now: now)
                action = .release(bid: amount)
                actionTitle = "Release and re-auction"
            case .available, .leased:
                throw TOSDNSManagementError.actionNotAllowed
            }
            let age = now >= state.observedAt ? now - state.observedAt : 0
            let network = wallet.network == .testnet ? "testnet" : "mainnet"
            let confirmation = UIAlertController(
                title: actionTitle,
                message: "Domain: \(state.canonicalName)\nNetwork: \(network)\nDestination: \(state.itemAddress.toRaw())\nAmount: \(formatTOS(amount)) TOS\nCheckpoint: \(state.masterchainSequence) (\(age)s old)\n\nState and amount are checked again before signing.",
                preferredStyle: .alert
            )
            confirmation.addAction(UIAlertAction(title: TKLocales.Actions.cancel, style: .cancel))
            confirmation.addAction(UIAlertAction(title: TKLocales.Actions.continueAction, style: .default) { [weak self] _ in
                self?.openDomainManagement(wallet: wallet, name: name, action: action)
            })
            router.rootViewController.present(confirmation, animated: true)
        } catch {
            ToastPresenter.showToast(configuration: .init(title: "Domain action is unavailable or chain state could not be verified."))
        }
    }

    func openDomainRegistration(wallet: Wallet, name: String) {
        guard let windowScene = UIApplication.keyWindowScene else { return }
        let window = TKWindow(windowScene: windowScene)
        let coordinator = RegisterDNSCoordinator(
            router: WindowRouter(window: window), name: name, wallet: wallet,
            keeperCoreMainAssembly: keeperCoreMainAssembly, coreAssembly: coreAssembly
        )
        coordinator.didCancel = { [weak self, weak coordinator] in
            guard let coordinator else { return }
            self?.removeChild(coordinator)
        }
        coordinator.didFinish = { [weak self] coordinator in
            self?.removeChild(coordinator)
        }
        registerDNSCoordinator = coordinator
        addChild(coordinator)
        coordinator.start()
    }

    func openDomainManagement(wallet: Wallet, name: String, action: TOSDNSManagementAction) {
        guard let windowScene = UIApplication.keyWindowScene else { return }
        let window = TKWindow(windowScene: windowScene)
        let coordinator = ManageDNSCoordinator(
            router: WindowRouter(window: window), name: name, action: action, wallet: wallet,
            keeperCoreMainAssembly: keeperCoreMainAssembly, coreAssembly: coreAssembly
        )
        coordinator.didCancel = { [weak self, weak coordinator] in
            guard let coordinator else { return }
            self?.removeChild(coordinator)
        }
        coordinator.didFinish = { [weak self] coordinator in self?.removeChild(coordinator) }
        manageDNSCoordinator = coordinator
        addChild(coordinator)
        coordinator.start()
    }

    func formatTOS(_ amount: BigUInt) -> String {
        let divisor = BigUInt(1_000_000_000)
        let whole = amount / divisor
        let remainder = amount % divisor
        guard remainder > 0 else { return whole.description }
        let fraction = String(repeating: "0", count: 9 - remainder.description.count) + remainder.description
        return whole.description + "." + fraction.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }
}
