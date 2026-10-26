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
                if Task.isCancelled { return }
                await MainActor.run {
                    ToastPresenter.hideAll()
                    didPrepareForPresent?()
                    let alert = UIAlertController(title: "Wallet Recovery Unavailable",
                        message: "Unable to restore your wallets. Please try again.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.didCancel?() })
                    router.rootViewController.present(alert, animated: true)
                }
            }
        }
    }
}

private extension PublicKeyImportCoordinator {
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
