import KeeperCore
import SignRaw
import TKCoordinator
import TKCore
import TKUIKit
import UIKit

final class RegisterDNSCoordinator: RouterCoordinator<WindowRouter> {
    var didCancel: (() -> Void)?

    private weak var walletTransferSignCoordinator: WalletTransferSignCoordinator?
    private let name: String
    private let wallet: Wallet
    private let keeperCoreMainAssembly: KeeperCore.MainAssembly
    private let coreAssembly: TKCore.CoreAssembly

    init(
        router: WindowRouter,
        name: String,
        wallet: Wallet,
        keeperCoreMainAssembly: KeeperCore.MainAssembly,
        coreAssembly: TKCore.CoreAssembly
    ) {
        self.name = name
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
            transferProvider: { [name] in .registerDNS(name: name) },
            resultHandler: RegisterDNSResultHandler(
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
                let signer = WalletTransferSignCoordinator(
                    router: router, wallet: wallet, transferData: transferData,
                    keeperCoreMainAssembly: keeperCoreMainAssembly, coreAssembly: coreAssembly
                )
                walletTransferSignCoordinator = signer
                return try await signer.handleSign(parentCoordinator: coordinator).get()
            }
        )
    }
}

private struct RegisterDNSResultHandler: SignRawControllerResultHandler {
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
