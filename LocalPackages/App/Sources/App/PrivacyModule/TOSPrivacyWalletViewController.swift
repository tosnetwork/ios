import UIKit
import UniformTypeIdentifiers
import KeeperCore
import CoreComponents
import TonSwift

/// Independent privacy mode. No ordinary balance, ordinary receiving QR or
/// unauthenticated RPC amount is displayed here.
@MainActor
final class TOSPrivacyWalletViewController: UIViewController, UIDocumentPickerDelegate {
    struct PaymentConfiguration {
        let phase1: URL
        let ceremony: URL
        let approvedRelay: Data
        let approvedRecoveryRelay: Data
        let testPool: TOSPrivacyPoolSelection?

        private static func parsePool(_ pool: [String: String], globalID: Int32, source: String) -> TOSPrivacyPoolSelection? {
            func hash(_ key: String) -> Data? {
                guard let value = pool[key], value.utf8.count == 64,
                      value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
                var result = Data()
                var index = value.startIndex
                while index < value.endIndex {
                    let end = value.index(index, offsetBy: 2)
                    guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
                    result.append(byte)
                    index = end
                }
                return result
            }
            guard let root = pool["root_hash"], let file = pool["file_hash"],
                  let profile = try? TOSQuantumNetworkProfile(globalID: globalID, rootHash: root, fileHash: file),
                  let account = hash("pool_account"),
                  let codeText = pool["code_boc"], let code = Data(base64Encoded: codeText),
                  let profileHash = hash("profile_hash"), let manifest = hash("poseidon_manifest_hash"),
                  let vk = hash("groth16_vk_hash"),
                  let selection = try? TOSPrivacyPoolSelection(profile: profile, address: Address(workchain: 0, hash: account), codeBOC: code,
                      profileHash: profileHash, manifestHash: manifest, verifyingKeyHash: vk,
                      sourceDescription: source) else { return nil }
            return selection
        }

        static func bundledRelease() -> Self? {
            guard let directory = Bundle.main.resourceURL?.appendingPathComponent("PrivacyPayment", isDirectory: true),
                  let bytes = try? Data(contentsOf: directory.appendingPathComponent("relay.json"), options: .mappedIfSafe),
                  (1...256 * 1024).contains(bytes.count),
                  var relay = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                  let poolBytes = try? Data(contentsOf: directory.appendingPathComponent("pool.json"), options: .mappedIfSafe),
                  (1...256 * 1024).contains(poolBytes.count),
                  let pool = (try? JSONSerialization.jsonObject(with: poolBytes)) as? [String: String],
                  let globalID = pool["global_id"].flatMap(Int32.init),
                  let selection = parsePool(pool, globalID: globalID, source: "Bundled privacy pool") else { return nil }
            let phase1 = directory.appendingPathComponent("phase1", isDirectory: true)
            let ceremony = directory.appendingPathComponent("ceremony", isDirectory: true)
            guard FileManager.default.isReadableFile(atPath: phase1.path),
                  FileManager.default.isReadableFile(atPath: ceremony.path) else { return nil }
            relay.removeValue(forKey: "lifetime")
            guard let recovery = try? JSONSerialization.data(withJSONObject: relay) else { return nil }
            return Self(phase1: phase1, ceremony: ceremony, approvedRelay: bytes,
                        approvedRecoveryRelay: recovery, testPool: selection)
        }

        static func simulatorFixture() -> Self? {
            #if DEBUG && targetEnvironment(simulator)
            guard let path = ProcessInfo.processInfo.environment["TOS_PRIVACY_PAYMENT_FIXTURE"],
                  path.hasPrefix("/"),
                  let bytes = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                  bytes.count <= 256 * 1024,
                  let fields = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                  let phase1 = fields["phase1"] as? String,
                  let ceremony = fields["ceremony"] as? String,
                  let relay = fields["relay"] as? [String: Any],
                  let offer = try? JSONSerialization.data(withJSONObject: relay) else { return nil }
            var recovery = relay
            recovery.removeValue(forKey: "lifetime")
            guard let recovery = try? JSONSerialization.data(withJSONObject: recovery) else { return nil }
            let testPool: TOSPrivacyPoolSelection?
            if let pool = fields["test_pool"] as? [String: String] {
                guard let selection = parsePool(pool, globalID: 3, source: "Isolated simulator fixture") else { return nil }
                testPool = selection
            } else {
                testPool = nil
            }
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            func material(_ path: String) -> URL {
                path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appendingPathComponent(path, isDirectory: true)
            }
            return Self(phase1: material(phase1), ceremony: material(ceremony),
                        approvedRelay: offer, approvedRecoveryRelay: recovery, testPool: testPool)
            #else
            return nil
            #endif
        }
    }

    private enum State {
        case paymentProgress(String), paymentStatus(String)
        case loading, locked, unconfigured, receipt, recipientChecked(Bool), observed(TOSPrivacyWalletService.Observed), failed(String)
    }
    private let paymentConfiguration: PaymentConfiguration?
    private let retryPayment = UIButton(type: .system)
    private let send = UIButton(type: .system)
    private let withdraw = UIButton(type: .system)
    private let paymentAmount = UITextField()
    private let depositAmount = UITextField()
    private let deposit = UIButton(type: .system)
    private let reviewDeposit: (TOSQuantumPaymentIntent, UINavigationController) -> Void
    private let wallet: Wallet
    private let service: TOSPrivacyWalletService
    private let registry: TOSPrivacyPoolRegistry
    private let authenticate: @MainActor () async -> String?
    private let amount = UILabel(), status = UILabel(), pool = UILabel()
    private let refresh = UIButton(type: .system)
    private let receive = UIButton(type: .system)
    private let exportBackup = UIButton(type: .system), restoreBackup = UIButton(type: .system)
    private let checkPending = UIButton(type: .system)
    private let descriptor = UITextView()
    private let copyDescriptor = UIButton(type: .system)
    private let recipient = UITextField()
    private let checkRecipient = UIButton(type: .system)
    private var selection: TOSPrivacyPoolSelection?
    private var access: TOSPrivacyWalletService.Access?
    private var state = State.loading
    private var operation: Task<Void, Never>?
    private weak var paymentConfirmation: UIAlertController?
    private var requestID = UUID()
    private var busy = false

    init(wallet: Wallet, service: TOSPrivacyWalletService, registry: TOSPrivacyPoolRegistry,
         paymentConfiguration: PaymentConfiguration? = nil,
         authenticate: @escaping @MainActor () async -> String?,
         reviewDeposit: @escaping (TOSQuantumPaymentIntent, UINavigationController) -> Void) {
        self.paymentConfiguration = paymentConfiguration
        self.reviewDeposit = reviewDeposit
        self.wallet = wallet; self.service = service; self.registry = registry; self.authenticate = authenticate
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }
    private var stagedBackup: URL?

    deinit {
        operation?.cancel()
        if let stagedBackup { try? FileManager.default.removeItem(at: stagedBackup.deletingLastPathComponent()) }
    }

    override func viewDidLoad() {
        super.viewDidLoad(); title = "Privacy wallet"
        view.backgroundColor = UIColor(red: 0.08, green: 0.06, blue: 0.18, alpha: 1)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Ordinary wallet", style: .plain, target: self, action: #selector(close))
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .onDrag
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        ])
        func label(_ text: String, style: UIFont.TextStyle = .body) -> UILabel {
            let item = UILabel(); item.text = text; item.textColor = .white; item.numberOfLines = 0
            item.font = .preferredFont(forTextStyle: style); item.adjustsFontForContentSizeCategory = true; return item
        }
        stack.addArrangedSubview(label("◉ Private assets · TOS", style: .largeTitle))
        stack.addArrangedSubview(label(wallet.label))
        for (item, id) in [(amount, "balance"), (status, "status"), (pool, "pool")] {
            item.textColor = .white; item.numberOfLines = 0; item.font = .preferredFont(forTextStyle: item === amount ? .title1 : .body)
            item.adjustsFontForContentSizeCategory = true; item.accessibilityIdentifier = "privacy.wallet." + id
            stack.addArrangedSubview(item)
        }
        var config = UIButton.Configuration.filled(); config.title = "Refresh private balance"
        config.baseBackgroundColor = .systemIndigo; config.contentInsets = .init(top: 14, leading: 12, bottom: 14, trailing: 12)
        refresh.configuration = config; refresh.accessibilityIdentifier = "privacy.wallet.refresh"
        refresh.addAction(UIAction { [weak self] _ in self?.read() }, for: .touchUpInside); stack.addArrangedSubview(refresh)
        var receiveConfig = UIButton.Configuration.tinted(); receiveConfig.title = "Receive privately"
        receive.configuration = receiveConfig
        receive.accessibilityIdentifier = "privacy.wallet.receive"
        receive.addAction(UIAction { [weak self] _ in self?.read(forReceipt: true) }, for: .touchUpInside)
        stack.addArrangedSubview(receive)
        copyDescriptor.setTitle("Copy private receiving descriptor", for: .normal)
        copyDescriptor.accessibilityIdentifier = "privacy.wallet.descriptor.copy"
        copyDescriptor.addAction(UIAction { [weak self] _ in
            guard let self, let value = self.descriptor.text, !value.isEmpty else { return }
            UIPasteboard.general.setItems(
                [["public.utf8-plain-text": value]],
                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)]
            )
            UIAccessibility.post(notification: .announcement, argument: "Private receiving descriptor copied.")
        }, for: .touchUpInside)
        stack.addArrangedSubview(copyDescriptor)
        descriptor.isEditable = false
        descriptor.accessibilityIdentifier = "privacy.wallet.descriptor"
        descriptor.heightAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(descriptor)
        recipient.placeholder = "Private descriptor or ordinary TOS address"
        recipient.accessibilityIdentifier = "privacy.wallet.recipient"
        #if DEBUG && targetEnvironment(simulator)
        if paymentConfiguration?.testPool != nil,
           let fixtureRecipient = ProcessInfo.processInfo.environment["TOS_PRIVACY_TEST_RECIPIENT"],
           [3432, 66, 48].contains(fixtureRecipient.utf8.count) {
            recipient.text = fixtureRecipient
        }
        #endif
        recipient.autocorrectionType = .no
        recipient.autocapitalizationType = .none
        recipient.borderStyle = .roundedRect
        stack.addArrangedSubview(recipient)
        checkRecipient.setTitle("Check private recipient", for: .normal)
        checkRecipient.addAction(UIAction { [weak self] _ in
            guard let self, let input = recipient.text else { return }
            read(recipientInput: input)
        }, for: .touchUpInside)
        stack.addArrangedSubview(checkRecipient)
        paymentAmount.placeholder = "Amount in nanoTOS"
        paymentAmount.keyboardType = .numberPad
        let amountToolbar = UIToolbar()
        amountToolbar.items = [
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.paymentAmount.resignFirstResponder()
            })
        ]
        amountToolbar.sizeToFit()
        paymentAmount.inputAccessoryView = amountToolbar
        paymentAmount.borderStyle = .roundedRect
        paymentAmount.accessibilityIdentifier = "privacy.wallet.send.amount"
        paymentAmount.isHidden = paymentConfiguration == nil
        stack.addArrangedSubview(paymentAmount)
        send.setTitle("Send privately through Tor", for: .normal)
        send.accessibilityIdentifier = "privacy.wallet.send"
        send.addAction(UIAction { [weak self] _ in self?.reviewPayment() }, for: .touchUpInside)
        stack.addArrangedSubview(send)
        checkPending.setTitle("Check pending private payment", for: .normal)
        checkPending.accessibilityIdentifier = "privacy.wallet.pending"
        checkPending.addAction(UIAction { [weak self] _ in self?.read(forPending: true) }, for: .touchUpInside)
        stack.addArrangedSubview(checkPending)
        retryPayment.setTitle("Retry pending payment through Tor", for: .normal)
        retryPayment.accessibilityIdentifier = "privacy.wallet.send.retry"
        retryPayment.isHidden = paymentConfiguration == nil
        retryPayment.addAction(UIAction { [weak self] _ in self?.recoverPendingPayment() }, for: .touchUpInside)
        stack.addArrangedSubview(retryPayment)
        depositAmount.placeholder = "Deposit amount in nanoTOS"
        depositAmount.keyboardType = .numberPad
        depositAmount.borderStyle = .roundedRect
        depositAmount.accessibilityIdentifier = "privacy.wallet.deposit.amount"
        let depositKeyboard = UIToolbar()
        let dismissDepositKeyboard = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(finishDepositAmount))
        dismissDepositKeyboard.accessibilityIdentifier = "privacy.wallet.deposit.keyboard.done"
        depositKeyboard.items = [UIBarButtonItem(systemItem: .flexibleSpace), dismissDepositKeyboard]
        depositKeyboard.sizeToFit()
        depositAmount.inputAccessoryView = depositKeyboard
        stack.addArrangedSubview(depositAmount)
        deposit.setTitle("Deposit TOS", for: .normal)
        deposit.accessibilityIdentifier = "privacy.wallet.deposit"
        deposit.addAction(UIAction { [weak self] _ in self?.prepareDeposit() }, for: .touchUpInside)
        stack.addArrangedSubview(deposit)
        exportBackup.setTitle("Export encrypted privacy backup", for: .normal)
        exportBackup.accessibilityIdentifier = "privacy.wallet.backup.export"
        exportBackup.addAction(UIAction { [weak self] _ in self?.transferBackup(from: nil) }, for: .touchUpInside)
        stack.addArrangedSubview(exportBackup)
        restoreBackup.setTitle("Restore encrypted privacy backup", for: .normal)
        restoreBackup.accessibilityIdentifier = "privacy.wallet.backup.restore"
        restoreBackup.addAction(UIAction { [weak self] _ in self?.choosePrivacyBackup() }, for: .touchUpInside)
        stack.addArrangedSubview(restoreBackup)
        withdraw.setTitle("Withdraw through Tor", for: .normal)
        withdraw.accessibilityIdentifier = "privacy.wallet.withdraw"
        withdraw.isEnabled = paymentConfiguration != nil
        withdraw.addAction(UIAction { [weak self] _ in self?.reviewPayment(withdrawal: true) }, for: .touchUpInside)
        stack.addArrangedSubview(withdraw)
        if paymentConfiguration == nil {
            stack.addArrangedSubview(label("Private sending requires a configured Tor relay."))
        }
        stack.addArrangedSubview(label("Tor withdrawals pay an ordinary address. The recipient and withdrawal amount are public on chain."))
        stack.addArrangedSubview(label("Balance synchronization uses your configured TOS node. This does not mean wallet traffic is routed through Tor. Leaving this page keeps wallet recovery records."))
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foregrounded), name: UIApplication.didBecomeActiveNotification, object: nil)
        render(); loadSelection()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent { invalidate() }
    }
    @objc private func close() { invalidate(); dismiss(animated: true) }
    @objc private func finishDepositAmount() { depositAmount.resignFirstResponder() }
    @objc private func backgrounded() { invalidate(); state = .locked; render() }
    @objc private func foregrounded() {
        // Retry only local configuration lookup; never reopen authentication.
        if selection == nil && !busy { loadSelection() }
    }
    private func invalidate() {
        paymentConfirmation?.dismiss(animated: false)
        paymentConfirmation = nil
        descriptor.text = ""
        recipient.text = ""
        paymentAmount.text = ""
        operation?.cancel(); operation = nil; requestID = UUID(); busy = false
    }
    private func render() {
        refresh.isEnabled = !busy && selection != nil
        exportBackup.isEnabled = refresh.isEnabled && access != nil
        restoreBackup.isEnabled = exportBackup.isEnabled
        checkPending.isEnabled = exportBackup.isEnabled
        send.isEnabled = refresh.isEnabled && paymentConfiguration != nil
        withdraw.isEnabled = send.isEnabled
        paymentAmount.isEnabled = send.isEnabled
        depositAmount.isEnabled = refresh.isEnabled
        deposit.isEnabled = refresh.isEnabled
        retryPayment.isEnabled = send.isEnabled
        receive.isEnabled = refresh.isEnabled
        checkRecipient.isEnabled = refresh.isEnabled
        recipient.isEnabled = !busy && selection != nil
        descriptor.isHidden = descriptor.text.isEmpty
        copyDescriptor.isHidden = descriptor.isHidden
        pool.text = selection.map { "Pool: \($0.address.toRaw())\nConfiguration: \($0.sourceDescription)" }
        amount.text = "—"
        switch state {
        case .recipientChecked(let valid):
            status.text = valid ? "Recipient descriptor is valid for this pool." : "Invalid recipient descriptor for this pool."
        case .receipt: status.text = "Share this descriptor with the sender."
        case .paymentProgress(let message), .paymentStatus(let message): status.text = message
        case .loading: status.text = "Loading privacy wallet…"
        case .locked: status.text = "Authenticate to refresh your private balance."
        case .unconfigured: status.text = "No trusted privacy pool is configured for this wallet's network."
        case .failed(let message): status.text = message
        case .observed(let value):
            amount.text = value.summary.formattedBalance
            let date = Date(timeIntervalSince1970: TimeInterval(value.provenShardTime)).formatted()
            status.text = "Verified chain observation: \(date)\nThis balance does not subtract local pending payments."
        }
    }
    private func loadSelection() {
        let id = UUID(); requestID = id; busy = true; state = .loading; render()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if requestID == id { operation = nil; busy = false; render() } }
            do {
                let preparation = try await service.prepare(wallet: wallet); try Task.checkCancellation()
                guard requestID == id else { return }
                selection = registry.selection(for: preparation.profile); access = preparation.access
                state = selection == nil ? .unconfigured : .locked
            } catch {
                guard requestID == id else { return }; state = .failed("Unable to load this wallet's privacy configuration.")
            }
        }
    }
    private func recoverPendingPayment() {
        guard !busy, let selection, let access, let configuration = paymentConfiguration else { return }
        let id = UUID(); requestID = id; busy = true; state = .paymentProgress("Checking the pending payment through Tor…"); render()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if requestID == id { operation = nil; busy = false; render() } }
            do {
                let authorization: TOSPrivacyWalletService.Authorization
                switch access {
                case .appPasscode:
                    guard let password = await authenticate() else { state = .locked; return }
                    try Task.checkCancellation()
                    authorization = .appPasscode(password)
                case .devicePresence:
                    authorization = .devicePresence
                }
                let payment = try await service.recoverPayment(wallet: wallet, authorization: authorization,
                    selection: selection, approvedRelay: configuration.approvedRecoveryRelay)
                guard requestID == id else { return }
                guard let payment else {
                    state = .paymentStatus("No unresolved private payment. Refresh to verify your balance.")
                    return
                }
                _ = try await service.submitOrRetry(payment)
                guard requestID == id else { return }
                state = .paymentStatus("Relay responded. Refresh to verify payment confirmation against the chain.")
            } catch {
                guard requestID == id else { return }
                state = .failed("Unable to resolve the pending payment through Tor. Try checking it again.")
            }
        }
    }

    private func prepareDeposit() {
        view.endEditing(true)
        guard !busy, let selection, let access else { return }
        let text = depositAmount.text ?? ""
        guard let amount = UInt64(text), amount > 0, String(amount) == text else {
            state = .failed("Enter a positive deposit amount in nanoTOS.")
            render()
            return
        }
        let id = UUID(); requestID = id; busy = true
        state = .paymentProgress("Verifying the privacy pool and deposit fee…"); render()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if requestID == id { operation = nil; busy = false; render() } }
            do {
                let authorization: TOSPrivacyWalletService.Authorization
                switch access {
                case .appPasscode:
                    guard let password = await authenticate() else { state = .locked; return }
                    authorization = .appPasscode(password)
                case .devicePresence:
                    authorization = .devicePresence
                }
                try Task.checkCancellation()
                let value = try await service.depositValue(wallet: wallet, authorization: authorization,
                                                           selection: selection, amount: amount)
                let intent = try await service.prepareSelfDeposit(wallet: wallet, authorization: authorization,
                    selection: selection, amount: amount, attachedValue: value, queryID: UInt64.random(in: .min ... .max))
                try Task.checkCancellation()
                guard requestID == id else { return }
                state = .locked
                if let navigationController { reviewDeposit(intent, navigationController) }
            } catch {
                guard requestID == id else { return }
                state = .failed("Unable to prepare the deposit. Check the amount and your configured TOS node.")
            }
        }
    }

    private func reviewPayment(withdrawal: Bool = false) {
        guard !busy, let selection, let access, let configuration = paymentConfiguration else { return }
        let input = (recipient.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let value = paymentAmount.text ?? ""
        let ordinaryAddress = withdrawal ? try? TOSPrivacyWithdrawalRecipient.parse(input, network: wallet.network) : nil
        let destination = withdrawal ? ordinaryAddress?.toRaw().data(using: .utf8) : Data(base64Encoded: input)
        let validRecipient = withdrawal
            ? ordinaryAddress?.workchain == 0 && ordinaryAddress?.hash.count == 32
            : input.utf8.count == 3432 && destination?.count == 2573 && destination?.base64EncodedString() == input
        guard validRecipient, let destination,
              let amount = UInt64(value), amount > 0, String(amount) == value else {
            state = .failed(withdrawal ? "Enter an ordinary TOS address in workchain 0 for the selected network and a positive amount in nanoTOS." : "Enter a private recipient and a positive amount in nanoTOS.")
            render()
            return
        }
        let id = UUID(); requestID = id; busy = true; state = .paymentProgress("Preparing the private payment and Tor quote…"); render()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if requestID == id { operation = nil; busy = false; render() } }
            do {
                let authorization: TOSPrivacyWalletService.Authorization
                switch access {
                case .appPasscode:
                    guard let password = await authenticate() else { return }
                    try Task.checkCancellation()
                    authorization = .appPasscode(password)
                case .devicePresence:
                    authorization = .devicePresence
                }
                if !withdrawal {
                    guard try await service.validateRecipient(wallet: wallet, authorization: authorization,
                                                              selection: selection, input: input) else {
                        state = .recipientChecked(false)
                        return
                    }
                }
                let poolFee: String?
                if withdrawal {
                    poolFee = try await service.withdrawalFee(wallet: wallet, authorization: authorization, selection: selection)
                } else { poolFee = nil }
                guard requestID == id else { return }
                state = .paymentProgress("Loading private payment proof materials…"); render()
                let prover = try await service.loadPaymentProver(wallet: wallet, authorization: authorization,
                    selection: selection, phase1: configuration.phase1, ceremony: configuration.ceremony)
                guard requestID == id else { return }
                state = .paymentProgress("Requesting a Tor relay quote…"); render()
                let offer = try await service.requestRelayOffer(wallet: wallet, authorization: authorization,
                    selection: selection, approvedRelay: configuration.approvedRelay)
                let details = try offer.details()
                try Task.checkCancellation()
                guard requestID == id else { return }
                let confirmation = UIAlertController(title: withdrawal ? "Confirm Tor withdrawal" : "Confirm private payment",
                    message: (withdrawal ? "Privacy pool → ordinary address\nNetwork ID \(selection.profile.globalID)\n" : "") + "Amount \(value) nanoTOS\nRelay fee \(details.fee) nanoTOS\nRoute Tor\nRecipient \(withdrawal ? input : String(input.prefix(20)) + "…" + String(input.suffix(20)))" +
                        (poolFee.map { "\nPool fee \($0) nanoTOS\nThe recipient and withdrawal amount are public on chain. Tor hides your connection address from the relay; it does not make the payout untraceable." } ?? ""),
                    preferredStyle: .alert)
                confirmation.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                    self?.paymentConfirmation = nil
                })
                confirmation.addAction(UIAlertAction(title: "Confirm", style: .default) { [weak self] _ in
                    guard let self, requestID == id, !busy else { return }
                    paymentConfirmation = nil
                    submitPayment(id: id, authorization: authorization, selection: selection, recipient: destination,
                        amount: value, details: details, prover: prover, offer: offer, withdrawalFee: poolFee)
                })
                state = .locked
                paymentConfirmation = confirmation
                present(confirmation, animated: true)
            } catch {
                guard requestID == id else { return }
                state = .failed("Unable to prepare the Tor relay quote.")
            }
        }
    }

    private func submitPayment(
        id: UUID, authorization: TOSPrivacyWalletService.Authorization, selection: TOSPrivacyPoolSelection,
        recipient: Data, amount: String, details: TOSPrivacyNative.RelayOfferDetails,
        prover: TOSPrivacyNative.PaymentProver, offer: TOSPrivacyNative.RelayOffer, withdrawalFee: String? = nil
    ) {
        busy = true; state = .paymentProgress("Preparing and submitting the private payment through Tor…"); render()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if requestID == id { operation = nil; busy = false; render() } }
            do {
                let payment = try await service.stagePayment(wallet: wallet, authorization: authorization,
                    selection: selection, recipient: recipient, amount: amount, fee: details.fee,
                    quoteIdentity: details.identity, withdrawalFee: withdrawalFee, prover: prover, offer: offer)
                _ = try await service.submitOrRetry(payment)
                guard requestID == id else { return }
                state = .paymentStatus("Relay responded. Verify payment confirmation against the chain.")
            } catch {
                guard requestID == id else { return }
                state = .failed("Payment status is uncertain. Check the existing payment before trying again.")
            }
        }
    }

    private func choosePrivacyBackup() {
        guard !busy, selection != nil, access != nil else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if stagedBackup != nil {
            clearStagedBackup()
            state = .paymentStatus("Encrypted privacy backup saved.")
            render()
        } else if let url = urls.first {
            transferBackup(from: url)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        clearStagedBackup()
    }

    private func clearStagedBackup() {
        if let stagedBackup {
            try? FileManager.default.removeItem(at: stagedBackup.deletingLastPathComponent())
            self.stagedBackup = nil
        }
    }

    private func transferBackup(from source: URL?) {
        guard !busy, let selection, let access else { return }
        let id = UUID()
        requestID = id; busy = true; state = .loading; render()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if requestID == id { operation = nil; busy = false; render() } }
            do {
                let authorization: TOSPrivacyWalletService.Authorization
                switch access {
                case .appPasscode:
                    let password = await authenticate()
                    try Task.checkCancellation()
                    guard let password else { state = .locked; return }
                    authorization = .appPasscode(password)
                case .devicePresence:
                    authorization = .devicePresence
                }
                if let source {
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    try await service.transferBackup(wallet: wallet, authorization: authorization,
                                                     selection: selection, file: source, restore: true)
                    let balance = try await service.read(wallet: wallet, authorization: authorization, selection: selection)
                    try Task.checkCancellation()
                    guard requestID == id else { return }
                    state = .observed(balance)
                } else {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    let file = directory.appendingPathComponent("tos-privacy-backup.bin")
                    var handedToPicker = false
                    defer { if !handedToPicker { try? FileManager.default.removeItem(at: directory) } }
                    guard FileManager.default.createFile(atPath: file.path, contents: nil,
                        attributes: [.protectionKey: FileProtectionType.complete]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try await service.transferBackup(wallet: wallet, authorization: authorization,
                                                     selection: selection, file: file, restore: false)
                    try Task.checkCancellation()
                    guard requestID == id else { return }
                    let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
                    picker.delegate = self
                    stagedBackup = file
                    handedToPicker = true
                    state = .paymentStatus("Choose where to save the encrypted privacy backup.")
                    present(picker, animated: true)
                }
            } catch {
                guard requestID == id else { return }
                state = .failed(source == nil ? "Encrypted privacy backup could not be saved." :
                    "Restore could not be verified. Check the saved state before retrying. Restore requires the original recovery material and a fresh privacy wallet.")
            }
        }
    }

    private func read(forReceipt: Bool = false, forPending: Bool = false, recipientInput: String? = nil) {
        guard !busy, let selection, let access else { return }
        descriptor.text = ""
        let id = UUID(); requestID = id; busy = true; state = .loading; render()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if requestID == id { operation = nil; busy = false; render() } }
            do {
                let authorization: TOSPrivacyWalletService.Authorization
                switch access {
                case .appPasscode:
                    let password = await authenticate(); try Task.checkCancellation()
                    guard let password else { state = .locked; return }
                    authorization = .appPasscode(password)
                case .devicePresence:
                    authorization = .devicePresence
                }
                if let recipientInput {
                    let valid = try await service.validateRecipient(wallet: wallet, authorization: authorization,
                                                                    selection: selection, input: recipientInput)
                    try Task.checkCancellation(); guard requestID == id else { return }
                    state = .recipientChecked(valid)
                } else if forPending {
                    let pending = try await service.pendingStatus(wallet: wallet, authorization: authorization,
                                                                  selection: selection)
                    try Task.checkCancellation(); guard requestID == id else { return }
                    switch pending {
                    case .noRecord: state = .paymentStatus("No pending private payment.")
                    case .unobserved: state = .paymentStatus("The pool has not yet observed this payment. Its original request is retained.")
                    case .accepted: state = .paymentStatus("The pool accepted this private payment.")
                    }
                } else if forReceipt {
                    let result = try await service.receive(wallet: wallet, authorization: authorization, selection: selection)
                    try Task.checkCancellation(); guard requestID == id else { return }
                    descriptor.text = result.base64EncodedString()
                    state = .receipt
                } else {
                    let result = try await service.read(wallet: wallet, authorization: authorization, selection: selection)
                    try Task.checkCancellation(); guard requestID == id else { return }
                    state = .observed(result)
                }
            } catch {
                guard requestID == id else { return }
                if case TOSPrivacyWalletService.Failure.materialUnavailable = error {
                    state = .failed("This device does not have the original recovery material for your private assets. Restore your original wallet backup to continue.")
                } else if recipientInput != nil { state = .failed("Unable to verify the private recipient.") }
                else if forPending { state = .failed("Unable to verify the saved private payment. Refresh to try again.") }
                else { state = .failed(forReceipt ? "Unable to create a private receiving descriptor." : "Unable to verify your private balance. Refresh to try again.") }
            }
        }
    }
}
