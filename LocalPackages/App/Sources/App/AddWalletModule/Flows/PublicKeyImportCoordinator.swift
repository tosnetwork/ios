import KeeperCore
import TKCoordinator
import TKCore
import TKScreenKit
import TKUIKit
import TonSwift
import UIKit

public final class PublicKeyImportCoordinator: RouterCoordinator<NavigationControllerRouter> {
    public var didPrepareForPresent: (() -> Void)?
    public var didCancel: (() -> Void)?
    public var didImport: ((_ publicKey: TonSwift.PublicKey, _ revisions: [WalletContractVersion], _ model: CustomizeWalletModel) -> Void)?

    private let publicKey: TonSwift.PublicKey
    private let name: String?
    private let walletsUpdateAssembly: WalletsUpdateAssembly
    private let customizeWalletModule: () -> MVVMModule<UIViewController, CustomizeWalletModuleOutput, Void>

    init(
        publicKey: TonSwift.PublicKey,
        name: String?,
        router: NavigationControllerRouter,
        walletsUpdateAssembly: WalletsUpdateAssembly,
        customizeWalletModule: @escaping () -> MVVMModule<UIViewController, CustomizeWalletModuleOutput, Void>
    ) {
        self.publicKey = publicKey
        self.name = name
        self.walletsUpdateAssembly = walletsUpdateAssembly
        self.customizeWalletModule = customizeWalletModule
        super.init(router: router)
    }

    override public func start() {
        ToastPresenter.showToast(configuration: .loading)
        Task {
            do {
                let activeWalletModels = try await detectActiveWallets(publicKey: publicKey)
                await MainActor.run {
                    ToastPresenter.hideAll()
                    openCustomizeWallet(publicKey: publicKey, revisions: activeWalletModels.map { $0.revision })
                    didPrepareForPresent?()
                }
            } catch {
                await MainActor.run {
                    ToastPresenter.hideAll()
                    if Task.isCancelled { didCancel?(); return }
                    openRecoveryError()
                    didPrepareForPresent?()
                }
            }
        }
    }
}

private extension PublicKeyImportCoordinator {
    func openRecoveryError() {
        let viewController = TKEmptyViewController()
        let close: () -> Void = { [weak coordinator = self] in
            guard let coordinator else { return }
            if coordinator.router.rootViewController.viewControllers.count > 1 {
                coordinator.router.pop()
            } else {
                coordinator.didCancel?()
            }
        }
        viewController.configure(model: TKEmptyViewController.Model(
            title: "Wallet Recovery Unavailable",
            caption: "Unable to restore your wallets. Please try again.",
            buttons: [.init(title: "Close", action: close)]))
        viewController.setupLeftCloseButton(close)
        viewController.view.backgroundColor = .Background.page
        router.push(viewController: viewController, animated: false, onPopClosures: { [weak coordinator = self] in
            coordinator?.didCancel?()
        })
    }

    func detectActiveWallets(publicKey: TonSwift.PublicKey) async throws -> [ActiveWalletModel] {
        try await walletsUpdateAssembly.walletImportController().findActiveWallets(publicKey: publicKey, network: .mainnet)
    }

    func openCustomizeWallet(publicKey: TonSwift.PublicKey, revisions: [WalletContractVersion]) {
        let module = customizeWalletModule()

        module.output.didCustomizeWallet = { [weak self] model in
            self?.didImport?(publicKey, revisions, model)
        }

        if router.rootViewController.viewControllers.isEmpty {
            module.view.setupLeftCloseButton { [weak self] in
                self?.didCancel?()
            }
        } else {
            module.view.setupBackButton()
        }

        router.push(viewController: module.view, animated: true)
    }
}
