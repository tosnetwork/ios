import CoreComponents
import KeeperCore
import TKCoordinator
import TKCore
import TKLocalize
import TKLogging
import TKScreenKit
import TKUIKit
import TonSwift
import UIKit
import UserNotifications

public final class CreateWalletCoordinator: RouterCoordinator<ViewControllerRouter> {
    public var didCancel: (() -> Void)?
    public var didCreateWallet: (() -> Void)?

    private let walletsUpdateAssembly: WalletsUpdateAssembly
    private let analyticsProvider: AnalyticsProvider
    private var isManagingRecovery = false
    private var activeCreationID: UUID?
    private let storesAssembly: StoresAssembly
    private let customizeWalletModule: () -> MVVMModule<UIViewController, CustomizeWalletModuleOutput, Void>

    init(
        router: ViewControllerRouter,
        analyticsProvider: AnalyticsProvider,
        walletsUpdateAssembly: WalletsUpdateAssembly,
        storesAssembly: StoresAssembly,
        customizeWalletModule: @escaping () -> MVVMModule<UIViewController, CustomizeWalletModuleOutput, Void>
    ) {
        self.walletsUpdateAssembly = walletsUpdateAssembly
        self.analyticsProvider = analyticsProvider
        self.customizeWalletModule = customizeWalletModule
        self.storesAssembly = storesAssembly
        super.init(router: router)
    }

    override public func start() {
        let hasMnemonics = walletsUpdateAssembly.secureAssembly.mnemonicsRepository().hasMnemonics()
        // Recovery material can exist before the public wallet registration has
        // completed. Reuse its passcode even after an interrupted creation.
        if hasMnemonics {
            openConfirmPasscode()
        } else {
            openCreatePasscode()
        }
    }
}

private extension CreateWalletCoordinator {
    func openCreatePasscode() {
        let navigationController = TKNavigationController()
        navigationController.configureTransparentAppearance()
        let router = NavigationControllerRouter(rootViewController: navigationController)

        PasscodeCreateCoordinator.present(
            parentCoordinator: self,
            parentRouter: router,
            repositoriesAssembly: walletsUpdateAssembly.repositoriesAssembly,
            onCancel: { [weak self] in
                self?.router.dismiss(animated: true, completion: {
                    self?.didCancel?()
                })
            },
            onCreate: { [weak self] passcode in
                let phrase = TOSMnemonic.generate()
                self?.openBackupIntro(
                    router: router,
                    animated: true,
                    passcode: passcode,
                    phrase: phrase
                )
            }
        )

        self.router.present(navigationController, onDismiss: { [weak self] in
            if self?.isManagingRecovery != true { self?.didCancel?() }
        })
    }

    func openConfirmPasscode() {
        PasscodeInputCoordinator.present(
            parentCoordinator: self,
            parentRouter: self.router,
            mnemonicsRepository: walletsUpdateAssembly.secureAssembly.mnemonicsRepository(),
            securityStore: storesAssembly.securityStore,
            onCancel: { [weak self] in
                self?.didCancel?()
            },
            onInput: { [weak self] passcode in
                self?.chooseCreation(passcode: passcode)
            }
        )
    }

    func openCreationFlow(passcode: String, record: TOSQuantumCreationRecord? = nil) {
        activeCreationID = nil
        let navigationController = TKNavigationController()
        navigationController.configureTransparentAppearance()
        let childRouter = NavigationControllerRouter(rootViewController: navigationController)
        if let record {
            openCustomizeWallet(router: childRouter, animated: false, passcode: passcode,
                                phrase: [], backupDate: nil, resumeID: record.id)
        } else {
            openBackupIntro(router: childRouter, animated: false, passcode: passcode, phrase: TOSMnemonic.generate())
        }
        router.present(navigationController, onDismiss: { [weak self] in
            if self?.isManagingRecovery != true { self?.didCancel?() }
        })
    }

    func chooseCreation(passcode: String, page: Int = 0) {
        do {
            let inventory = try walletsUpdateAssembly.walletAddController().quantumEnrollmentInventory()
            let pending = inventory.entries
            let atCapacity = inventory.storedCount >= 64 || inventory.overflow
            guard !pending.isEmpty || atCapacity else { openCreationFlow(passcode: passcode); return }
            let page = min(page, max(0, (pending.count - 1) / 6))
            let start = page * 6, end = min(start + 6, pending.count)
            let alert = UIAlertController(title: "Resume wallet creation",
                message: atCapacity
                    ? "This device has reached its 64 wallet-record limit. Remove an unneeded wallet in Settings or clean up an unfinished record, then reload. Additional records may be hidden until space is freed."
                    : "Continue an unfinished wallet or remove a record you no longer need.", preferredStyle: .alert)
            for entry in pending[start..<end] {
                let title: String
                if let record = entry.record {
                    title = "\(record.published ? "Public record" : "Resume") \(record.identity.wallet.address.toRaw().prefix(12))…"
                } else { title = "Unavailable record \(entry.filename.prefix(12))…" }
                alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                    self?.reviewEnrollment(entry, passcode: passcode)
                })
            }
            if page > 0 { alert.addAction(UIAlertAction(title: "Previous records", style: .default) { [weak self] _ in self?.chooseCreation(passcode: passcode, page: page - 1) }) }
            if end < pending.count { alert.addAction(UIAlertAction(title: "More records", style: .default) { [weak self] _ in self?.chooseCreation(passcode: passcode, page: page + 1) }) }
            if !atCapacity { alert.addAction(UIAlertAction(title: "Create another wallet", style: .default) { [weak self] _ in self?.openCreationFlow(passcode: passcode) }) }
            alert.addAction(UIAlertAction(title: TKLocales.Actions.cancel, style: .cancel) { [weak self] _ in self?.didCancel?() })
            router.present(alert)
        } catch {
            let alert = UIAlertController(title: "Wallet recovery unavailable", message: "The saved wallet list or recovery storage cannot be read. Existing wallets and keys were kept. Try again after storage becomes available.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Try again", style: .default) { [weak self] _ in self?.chooseCreation(passcode: passcode) })
            alert.addAction(UIAlertAction(title: TKLocales.Actions.cancel, style: .cancel) { [weak self] _ in self?.didCancel?() })
            router.present(alert)
        }
    }

    func reviewEnrollment(_ entry: TOSQuantumCreationRecord.Entry, passcode: String) {
        let readable = entry.record != nil
        let published = entry.record?.published == true
        let alert = UIAlertController(title: published ? "Saved wallet public record" : "Unfinished wallet", message: published
            ? "Only this public record will be removed. Protected keys and encrypted recovery material are kept."
            : readable ? "Resume the original wallet or remove its local recovery record. Save your recovery phrase first: removal can make funds sent to this address inaccessible."
            : "This public record cannot be read. Removing it keeps protected keys and encrypted recovery material.", preferredStyle: .alert)
        if let record = entry.record, !record.published {
            alert.addAction(UIAlertAction(title: "Resume wallet", style: .default) { [weak self] _ in self?.openCreationFlow(passcode: passcode, record: record) })
        }
        alert.addAction(UIAlertAction(title: published ? "Remove public record" : readable ? "Remove unfinished wallet" : "Remove damaged public record", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                do {
                    try await self.walletsUpdateAssembly.walletAddController().discardQuantumEnrollment(entry, passcode: passcode)
                    await MainActor.run { self.chooseCreation(passcode: passcode) }
                } catch {
                    await MainActor.run {
                        let error = UIAlertController(title: "Recovery record kept", message: "Cleanup could not be completed. Try again without creating a replacement for this wallet.", preferredStyle: .alert)
                        error.addAction(UIAlertAction(title: TKLocales.Actions.cancel, style: .cancel))
                        self.router.present(error)
                    }
                }
            }
        })
        alert.addAction(UIAlertAction(title: TKLocales.Actions.cancel, style: .cancel) { [weak self] _ in self?.chooseCreation(passcode: passcode) })
        router.present(alert)
    }

    func openCustomizeWallet(
        router: NavigationControllerRouter,
        animated: Bool,
        passcode: String,
        phrase: [String],
        backupDate: Date?,
        resumeID: UUID? = nil
    ) {
        let module = customizeWalletModule()

        module.output.didCustomizeWallet = { [weak self, weak output = module.output] model in
            guard let self else { return }
            Task {
                let trace = Trace(name: "create_wallet")
                defer {
                    trace.stop()
                }

                do {
                    self.analyticsProvider.log(eventKey: .generateWallet)
                    try await self.createWallet(
                        model: model,
                        passcode: passcode,
                        phrase: phrase,
                        backupDate: backupDate,
                        resumeID: resumeID
                    )
                    await MainActor.run {
                        self.didCreateWallet?()
                        router.dismiss(animated: true)
                    }
                    trace.setValue("success", forAttribute: "result")
                } catch {
                    Log.e("Wallet creation failed", extraInfo: [
                        "error": error.localizedDescription,
                    ])
                    await MainActor.run {
                        output?.resetSubmission()
                        let alert = UIAlertController(
                            title: "Wallet creation failed",
                            message: error.localizedDescription,
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: "Configure TOS Node", style: .default) { _ in
                            DispatchQueue.main.async {
                                TOSRPCNodeEditor.present(from: router.rootViewController, onSaved: {})
                            }
                        })
                        alert.addAction(UIAlertAction(title: "Manage unfinished wallets", style: .default) { [weak coordinator = self] _ in
                            guard let coordinator else { return }
                            coordinator.isManagingRecovery = true
                            coordinator.router.dismiss(animated: true, completion: {
                                coordinator.isManagingRecovery = false
                                coordinator.chooseCreation(passcode: passcode)
                            })
                        })
                        alert.addAction(UIAlertAction(title: TKLocales.Actions.cancel, style: .cancel))
                        router.present(alert)
                    }
                    trace.setValue("fail", forAttribute: "result")
                }
            }
        }

        if router.rootViewController.viewControllers.isEmpty {
            module.view.setupLeftCloseButton { [weak self] in
                router.dismiss(animated: true) {
                    self?.didCancel?()
                }
            }
        } else {
            module.view.setupBackButton()
        }

        router.push(viewController: module.view, animated: animated)
    }

    func createWallet(
        model: CustomizeWalletModel,
        passcode: String,
        phrase: [String],
        backupDate: Date?,
        resumeID: UUID? = nil
    ) async throws {
        let addController = walletsUpdateAssembly.walletAddController()
        let metaData = WalletMetaData(
            label: model.name,
            tintColor: model.tintColor,
            icon: model.icon
        )
        if let retainedID = resumeID ?? activeCreationID {
            try await addController.resumeQuantumCreation(id: retainedID, metaData: metaData, passcode: passcode,
                setupSettings: WalletSetupSettings(backupDate: backupDate))
            return
        }
        try await addController.createWallet(
            metaData: metaData,
            passcode: passcode,
            mnemonicWords: phrase,
            setupSettings: WalletSetupSettings(backupDate: backupDate),
            onEnrollment: { [weak self] id in self?.activeCreationID = id }
        )
    }
}

private extension CreateWalletCoordinator {
    func openBackupIntro(
        router: NavigationControllerRouter,
        animated: Bool,
        passcode: String,
        phrase: [String]
    ) {
        let model = OnboardingInfoView.Model(
            icon: .TKUIKit.Icons.Size128.textbook,
            title: TKLocales.Onboarding.BackupIntro.title,
            subtitle: TKLocales.Onboarding.BackupIntro.caption,
            buttonTitle: TKLocales.Actions.continueAction
        )
        let viewController = OnboardingInfoViewController(model: model)
        viewController.isInteractivePopDisabled = true
        viewController.didTapContinue = { [weak self] in
            self?.openRecoveryPhrase(
                router: router,
                passcode: passcode,
                phrase: phrase
            )
        }
        viewController.navigationItem.hidesBackButton = true
        viewController.navigationItem.leftBarButtonItem = nil
        viewController.navigationItem.rightBarButtonItem = UIBarButtonItem(
            customView: makeLaterButton { [weak self] in
                self?.openCustomizeWallet(
                    router: router,
                    animated: true,
                    passcode: passcode,
                    phrase: phrase,
                    backupDate: nil
                )
            }
        )
        router.push(viewController: viewController, animated: animated)
    }

    func openRecoveryPhrase(
        router: NavigationControllerRouter,
        passcode: String,
        phrase: [String]
    ) {
        var provider = OnboardingRecoveryPhraseDataProvider(phrase: phrase)
        provider.didTapNext = { [weak self] in
            self?.openCheckRecoveryPhrase(
                router: router,
                passcode: passcode,
                phrase: phrase
            )
        }
        let module = TKRecoveryPhraseAssembly.module(provider: provider)
        module.viewController.setupBackButton()
        router.push(viewController: module.viewController)
    }

    func openCheckRecoveryPhrase(
        router: NavigationControllerRouter,
        passcode: String,
        phrase: [String]
    ) {
        let module = TKCheckRecoveryPhraseAssembly.module(
            provider: OnboardingCheckRecoveryPhraseProvider(phrase: phrase)
        )
        module.output.didCheckRecoveryPhrase = { [weak self] in
            self?.openCustomizeWallet(
                router: router,
                animated: true,
                passcode: passcode,
                phrase: phrase,
                backupDate: Date()
            )
        }
        module.viewController.setupBackButton()
        router.push(viewController: module.viewController)
    }
}

private extension CreateWalletCoordinator {
    func makeLaterButton(action: @escaping () -> Void) -> UIView {
        let button = TKUIHeaderTitleIconButton()
        button.configure(
            model: TKUIButtonTitleIconContentView.Model(
                title: TKLocales.Onboarding.BackupIntro.later
            )
        )
        button.addTapAction(action)
        button.tapAreaInsets = UIEdgeInsets(top: -10, left: -10, bottom: -10, right: -10)
        return button
    }
}
