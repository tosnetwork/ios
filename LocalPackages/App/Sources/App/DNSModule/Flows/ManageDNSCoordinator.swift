import KeeperCore
import SignRaw
import TKCoordinator
import TKCore
import TKUIKit
import UIKit

final class ManageDNSCoordinator: RouterCoordinator<WindowRouter> {
    var didCancel: (() -> Void)?
    var didFinish: ((ManageDNSCoordinator) -> Void)?

    private weak var walletTransferSignCoordinator: WalletTransferSignCoordinator?
    private let transfer: Transfer
    private let wallet: Wallet
    private let keeperCoreMainAssembly: KeeperCore.MainAssembly
    private let coreAssembly: TKCore.CoreAssembly

    init(
        router: WindowRouter,
        nft: NFT,
        action: TOSDNSManagementAction,
        wallet: Wallet,
        keeperCoreMainAssembly: KeeperCore.MainAssembly,
        coreAssembly: TKCore.CoreAssembly
    ) {
        transfer = .manageDNS(nft: nft, action: action)
        self.wallet = wallet
        self.keeperCoreMainAssembly = keeperCoreMainAssembly
        self.coreAssembly = coreAssembly
        super.init(router: router)
    }

    init(
        router: WindowRouter,
        name: String,
        action: TOSDNSManagementAction,
        wallet: Wallet,
        keeperCoreMainAssembly: KeeperCore.MainAssembly,
        coreAssembly: TKCore.CoreAssembly
    ) {
        transfer = .manageDNSName(name: name, action: action)
        self.wallet = wallet
        self.keeperCoreMainAssembly = keeperCoreMainAssembly
        self.coreAssembly = coreAssembly
        super.init(router: router)
    }

    func handleTosWalletPublishDeeplink(sign: Data) -> Bool {
        guard let signer = walletTransferSignCoordinator else { return false }
        signer.externalSignHandler?(sign)
        signer.externalSignHandler = nil
        return true
    }

    override func start() {
        guard let windowScene = router.window.windowScene else { return }
        SignRawPresenter.presentSignRaw(
            windowScene: windowScene,
            windowLevel: .signRaw,
            wallet: wallet,
            transferProvider: { [transfer] in transfer },
            resultHandler: ManageDNSResultHandler(
                didConfirm: { [weak self] in
                    guard let self else { return }
                    didFinish?(self)
                },
                didCancel: { [weak self] in self?.didCancel?() }
            ),
            sendFrom: .tonconnectRemote,
            coreAssembly: coreAssembly,
            keeperCoreMainAssembly: keeperCoreMainAssembly,
            didRequireSign: { [weak self] transferData, wallet, coordinator, router throws(WalletTransferSignError) in
                guard let self else { throw .cancelled }
                return try await self.didRequireSign(
                    transferData: transferData,
                    wallet: wallet,
                    coordinator: coordinator,
                    router: router
                )
            }
        )
    }

    @MainActor
    private func didRequireSign(
        transferData: TransferData,
        wallet: Wallet,
        coordinator: Coordinator,
        router: ViewControllerRouter
    ) async throws(WalletTransferSignError) -> SignedTransactions {
        let signer = WalletTransferSignCoordinator(
            router: router,
            wallet: wallet,
            transferData: transferData,
            keeperCoreMainAssembly: keeperCoreMainAssembly,
            coreAssembly: coreAssembly
        )
        walletTransferSignCoordinator = signer
        return try await signer.handleSign(parentCoordinator: coordinator).get()
    }
}

private struct ManageDNSResultHandler: SignRawControllerResultHandler {
    let didConfirmHandler: () -> Void
    let didCancelHandler: () -> Void

    init(didConfirm: @escaping () -> Void, didCancel: @escaping () -> Void) {
        didConfirmHandler = didConfirm
        didCancelHandler = didCancel
    }

    func didConfirm(boc _: String) { didConfirmHandler() }
    func didFail(error _: SomeOf<TransferError, TransactionConfirmationError>) { didCancelHandler() }
    func didCancel() { didCancelHandler() }
}
