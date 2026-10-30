import KeeperCore
import TKCoordinator
import TKCore
import TKLocalize
import TKLogging
import TKScreenKit
import TKUIKit
import TonSwift
import UIKit

final class ImportWalletCoordinator: RouterCoordinator<NavigationControllerRouter> {
    var didCancel: (() -> Void)?
    var didImportWallets: (() -> Void)?

    private var mnemonicFormat: WalletMnemonicFormat?
    private var importsQuantumWallet = false
    private var quantumRecoveryProfile: TOSQuantumNetworkProfile?
    private weak var recoveryPhraseInputViewController: TKInputRecoveryPhraseViewController?
    private let network: Network
    private let analyticsProvider: AnalyticsProvider
    private let walletsUpdateAssembly: WalletsUpdateAssembly
    private let storesAssembly: StoresAssembly
    private let customizeWalletModule: () -> MVVMModule<UIViewController, CustomizeWalletModuleOutput, Void>

    init(
        router: NavigationControllerRouter,
        analyticsProvider: AnalyticsProvider,
        walletsUpdateAssembly: WalletsUpdateAssembly,
        storesAssembly: StoresAssembly,
        network: Network,
        customizeWalletModule: @escaping () -> MVVMModule<UIViewController, CustomizeWalletModuleOutput, Void>
    ) {
        self.analyticsProvider = analyticsProvider
        self.walletsUpdateAssembly = walletsUpdateAssembly
        self.storesAssembly = storesAssembly
        self.network = network
        self.customizeWalletModule = customizeWalletModule
        super.init(router: router)
    }

    override func start() {
        openRecoveryPhraseInput()
    }
}

private extension ImportWalletCoordinator {
    func openRecoveryPhraseInput() {
        let inputRecoveryPhrase = TKInputRecoveryPhraseAssembly.module(
            title: TKLocales.ImportWallet.title,
            caption: TKLocales.ImportWallet.description,
            set12WordsButtonTitle: TKLocales.ImportWallet.set12Words,
            set24WordsButtonTitle: TKLocales.ImportWallet.set24Words,
            continueButtonTitle: TKLocales.Actions.continueAction,
            pasteButtonTitle: TKLocales.Actions.paste,
            validator: AddWalletInputRecoveryPhraseValidator(),
            suggestsProvider: AddWalletInputRecoveryPhraseSuggestsProvider()
        )
        recoveryPhraseInputViewController = inputRecoveryPhrase.viewController

        inputRecoveryPhrase.output.didInputRecoveryPhrase = { [weak self] phrase, completion in
            guard let self = self else { return }
            self.chooseMnemonicFormat(phrase: phrase, completion: completion)
        }

        if router.rootViewController.viewControllers.isEmpty {
            inputRecoveryPhrase.viewController.setupLeftCloseButton { [weak self] in
                self?.didCancel?()
            }
        } else {
            inputRecoveryPhrase.viewController.setupBackButton()
        }

        router.push(
            viewController: inputRecoveryPhrase.viewController,
            animated: true,
            onPopClosures: { [weak self] in
                self?.didCancel?()
            },
            completion: nil
        )
    }

    func chooseMnemonicFormat(phrase: [String], completion: @escaping () -> Void) {
        let formats = WalletMnemonicFormat.validFormats(words: phrase)
        if formats == [.tos] {
            mnemonicFormat = .tos
            let alert = UIAlertController(title: "Restore TOS Wallet", message: "Choose which wallet identity to restore from this TOS phrase.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Quantum Wallet", style: .default) { [weak self] _ in
                guard let self else { completion(); return }
                self.confirmQuantumRecoveryNetwork(phrase: phrase, completion: completion)
            })
            alert.addAction(UIAlertAction(title: "Classic TOS Wallets", style: .default) { [weak self] _ in
                guard let self else { completion(); return }
                self.importsQuantumWallet = false
                completion()
                self.detectActiveWallets(phrase: phrase, completion: {})
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion() })
            router.rootViewController.present(alert, animated: true)
            return
        }
        let alert = UIAlertController(
            title: formats.count > 1 ? "Recovery Phrase Format" : "Legacy Recovery Phrase",
            message: "Legacy TON recovery preserves the existing keys and wallet address. Choose TOS only for a phrase created by a TOS wallet.",
            preferredStyle: .alert
        )
        if formats.contains(.tos) {
            alert.addAction(UIAlertAction(title: "Restore Quantum Wallet", style: .default) { [weak self] _ in
                self?.confirmQuantumRecoveryNetwork(phrase: phrase, completion: completion)
            })
            alert.addAction(UIAlertAction(title: "Restore Classic TOS Wallets", style: .default) { [weak self] _ in
                self?.mnemonicFormat = .tos
                self?.importsQuantumWallet = false
                self?.detectActiveWallets(phrase: phrase, completion: completion)
            })
        }
        alert.addAction(UIAlertAction(title: "Restore Legacy Wallet", style: .default) { [weak self] _ in
            self?.mnemonicFormat = .legacyTON
            self?.importsQuantumWallet = false
            self?.detectActiveWallets(phrase: phrase, completion: completion)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion() })
        router.rootViewController.present(alert, animated: true)
    }

    func confirmQuantumRecoveryNetwork(phrase: [String], completion: @escaping () -> Void) {
        let profile: TOSQuantumNetworkProfile
        do { profile = try TOSQuantumNetworkProfile.effective() }
        catch {
            completion()
            let alert = UIAlertController(title: "Trusted Network Unavailable", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Configure Network", style: .default) { [weak self] _ in
                guard let self else { return }
                TOSRPCNodeEditor.present(from: self.router.rootViewController) { [weak self] in
                    self?.confirmQuantumRecoveryNetwork(phrase: phrase, completion: {})
                }
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            router.rootViewController.present(alert, animated: true)
            return
        }

        let message = "This phrase will be restored on the network below. It must match the profile shown when you backed up the wallet. If these values differ, cancel and configure the matching trusted profile first.\n\nGlobal ID: \(profile.globalID)\nZerostate root hash: \(profile.rootHash)\nZerostate file hash: \(profile.fileHash)"
        let alert = UIAlertController(title: "Confirm Recovery Network", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Use This Network", style: .default) { [weak self] _ in
            guard let self else { completion(); return }
            self.preflightQuantumRecovery(phrase: phrase, profile: profile, completion: completion)
        })
        alert.addAction(UIAlertAction(title: "Change Trusted Network", style: .default) { [weak self] _ in
            guard let self else { completion(); return }
            TOSRPCNodeEditor.present(from: self.router.rootViewController) { [weak self] in
                self?.confirmQuantumRecoveryNetwork(phrase: phrase, completion: {})
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion() })
        router.rootViewController.present(alert, animated: true)
    }

    func preflightQuantumRecovery(phrase: [String], profile: TOSQuantumNetworkProfile, completion: @escaping () -> Void) {
        recoveryPhraseInputViewController?.clearRecoveryPhraseInput()
        let progress = UIAlertController(title: "Verifying Trusted Network",
            message: "Checking a fresh proof against this profile before continuing wallet recovery.",
            preferredStyle: .alert)
        router.rootViewController.present(progress, animated: true)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.walletsUpdateAssembly.walletAddController().preflightQuantumNetwork(profile: profile)
                await MainActor.run {
                    progress.dismiss(animated: false) {
                        self.mnemonicFormat = .tos
                        self.importsQuantumWallet = true
                        self.quantumRecoveryProfile = profile
                        completion()
                        self.handleDidChooseRevisions(phrase: phrase, revisions: [])
                    }
                }
            } catch {
                await MainActor.run {
                    progress.dismiss(animated: false) {
                        completion()
                        self.presentQuantumRecoveryPreflightFailure(error, phrase: phrase, profile: profile)
                    }
                }
            }
        }
    }

    func presentQuantumRecoveryPreflightFailure(_ error: Error, phrase: [String], profile: TOSQuantumNetworkProfile) {
        let failure = UIAlertController(title: "TOS Node Unavailable",
            message: error.localizedDescription,
            preferredStyle: .alert)
        failure.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            self?.preflightQuantumRecovery(phrase: phrase, profile: profile, completion: {})
        })
        failure.addAction(UIAlertAction(title: "Configure TOS Node", style: .default) { [weak self] _ in
            guard let root = self?.router.rootViewController else { return }
            TOSRPCNodeEditor.present(from: root) { [weak self] in
                // The editor can change the trust anchor as well as the RPC URL.
                // Read and confirm the saved profile before retrying recovery.
                self?.confirmQuantumRecoveryNetwork(phrase: phrase, completion: {})
            }
        })
        failure.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        router.rootViewController.present(failure, animated: true)
    }

    func detectActiveWallets(phrase: [String], completion: @escaping () -> Void) {
        Task {
            do {
                let activeWallets = try await walletsUpdateAssembly.walletImportController().findActiveWallets(
                    phrase: phrase,
                    network: network,
                    format: mnemonicFormat
                )
                await MainActor.run {
                    completion()
                    handleActiveWallets(phrase: phrase, activeWalletModels: activeWallets)
                }
            } catch {
                Log.w("\(error)")
                await MainActor.run {
                    completion()
                }
            }
        }
    }

    func handleActiveWallets(phrase: [String], activeWalletModels: [ActiveWalletModel]) {
        handleDidChooseRevisions(phrase: phrase, revisions: activeWalletModels.map { $0.revision })
    }

    func handleDidChooseRevisions(phrase: [String], revisions: [WalletContractVersion]) {
        let hasMnemonics = walletsUpdateAssembly.secureAssembly.mnemonicsRepository().hasMnemonics()
        let hasRegisteredWallet = { [walletsUpdateAssembly] in
            do {
                return try !walletsUpdateAssembly.repositoriesAssembly.keeperInfoRepository().getKeeperInfo().wallets.isEmpty
            } catch {
                return false
            }
        }()
        if hasMnemonics, hasRegisteredWallet {
            openConfirmPasscode(phrase: phrase, revisions: revisions)
        } else {
            openCreatePasscode(phrase: phrase, revisions: revisions)
        }
    }

    func openCreatePasscode(phrase: [String], revisions: [WalletContractVersion]) {
        let coordinator = PasscodeCreateCoordinator(
            router: router
        )

        coordinator.didCancel = { [weak self, weak coordinator] in
            self?.removeChild(coordinator)
            self?.router.dismiss(animated: true, completion: {
                self?.didCancel?()
            })
        }

        coordinator.didCreatePasscode = { [weak self] passcode in
            self?.openCustomizeWallet(
                phrase: phrase,
                revisions: revisions,
                passcode: passcode,
                animated: true
            )
        }

        addChild(coordinator)
        coordinator.start()
    }

    func openConfirmPasscode(phrase: [String], revisions: [WalletContractVersion]) {
        PasscodeInputCoordinator.present(
            parentCoordinator: self,
            parentRouter: self.router,
            mnemonicsRepository: walletsUpdateAssembly.secureAssembly.mnemonicsRepository(),
            securityStore: storesAssembly.securityStore,
            onCancel: {},
            onInput: { [weak self] passcode in
                self?.openCustomizeWallet(
                    phrase: phrase,
                    revisions: revisions,
                    passcode: passcode,
                    animated: true
                )
            }
        )
    }

    func openCustomizeWallet(
        phrase: [String],
        revisions: [WalletContractVersion],
        passcode: String,
        animated: Bool
    ) {
        let module = customizeWalletModule()

        module.output.didCustomizeWallet = { [weak self, weak output = module.output] model in
            guard let self else { return }
            Task {
                do {
                    try await self.importWallet(
                        phrase: phrase,
                        revisions: revisions,
                        model: model,
                        passcode: passcode
                    )
                    await MainActor.run {
                        self.didImportWallets?()
                    }
                } catch {
                    Log.e("Log: Wallet import failed", extraInfo: [
                        "error": error.localizedDescription,
                    ])
                    await MainActor.run {
                        output?.resetSubmission()
                        let alert = UIAlertController(title: "Wallet import failed", message: error.localizedDescription, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "Configure TOS Node", style: .default) { _ in
                            DispatchQueue.main.async {
                                TOSRPCNodeEditor.present(from: self.router.rootViewController, onSaved: {})
                            }
                        })
                        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                        self.router.rootViewController.present(alert, animated: true)
                    }
                }
            }
        }

        module.view.setupBackButton()
        router.push(viewController: module.view, animated: animated)
    }

    func importWallet(
        phrase: [String],
        revisions: [WalletContractVersion],
        model: CustomizeWalletModel,
        passcode: String
    ) async throws {
        self.analyticsProvider.log(eventKey: .importWallet)

        let addController = walletsUpdateAssembly.walletAddController()
        let metaData = WalletMetaData(
            label: model.name,
            tintColor: model.tintColor,
            icon: model.icon
        )
        if mnemonicFormat == .tos, importsQuantumWallet {
            guard let profile = quantumRecoveryProfile else {
                throw NSError(
                    domain: "TOSQuantumRecovery",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The confirmed recovery network is unavailable. Re-enter the phrase and confirm the network."]
                )
            }
            try await addController.importQuantumWallet(
                metaData: metaData,
                passcode: passcode,
                mnemonicWords: phrase,
                profile: profile
            )
            return
        }
        try await addController.importWallets(
            phrase: phrase,
            revisions: revisions,
            metaData: metaData,
            passcode: passcode,
            network: network,
            format: mnemonicFormat
        )
    }
}
