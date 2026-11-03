import UIKit
import KeeperCore
import CoreComponents

/// Independent privacy mode. No ordinary balance, ordinary receiving QR or
/// unauthenticated RPC amount is displayed here.
@MainActor
final class TOSPrivacyWalletViewController: UIViewController {
    private enum State {
        case loading, locked, unconfigured, receipt, recipientChecked(Bool), observed(TOSPrivacyWalletService.Observed), failed(String)
    }
    private let wallet: Wallet
    private let service: TOSPrivacyWalletService
    private let registry: TOSPrivacyPoolRegistry
    private let authenticate: @MainActor () async -> String?
    private let amount = UILabel(), status = UILabel(), pool = UILabel()
    private let refresh = UIButton(type: .system)
    private let receive = UIButton(type: .system)
    private let descriptor = UITextView()
    private let recipient = UITextField()
    private let checkRecipient = UIButton(type: .system)
    private var selection: TOSPrivacyPoolSelection?
    private var access: TOSPrivacyWalletService.Access?
    private var state = State.loading
    private var operation: Task<Void, Never>?
    private var requestID = UUID()
    private var busy = false

    init(wallet: Wallet, service: TOSPrivacyWalletService, registry: TOSPrivacyPoolRegistry,
         authenticate: @escaping @MainActor () async -> String?) {
        self.wallet = wallet; self.service = service; self.registry = registry; self.authenticate = authenticate
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }
    deinit { operation?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad(); title = "Privacy wallet"
        view.backgroundColor = UIColor(red: 0.08, green: 0.06, blue: 0.18, alpha: 1)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Ordinary wallet", style: .plain, target: self, action: #selector(close))
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
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
        descriptor.isEditable = false
        descriptor.accessibilityIdentifier = "privacy.wallet.descriptor"
        descriptor.heightAnchor.constraint(equalToConstant: 140).isActive = true
        stack.addArrangedSubview(descriptor)
        recipient.placeholder = "Private recipient descriptor"
        recipient.accessibilityIdentifier = "privacy.wallet.recipient"
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
        for title in ["Send privately", "Deposit TOS", "Withdraw TOS"] {
            let button = UIButton(type: .system); var config = UIButton.Configuration.tinted(); config.title = title
            button.configuration = config; button.isEnabled = false; stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(label("Sending, depositing and withdrawing are still in development."))
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
    @objc private func backgrounded() { invalidate(); state = .locked; render() }
    @objc private func foregrounded() {
        // Retry only local configuration lookup; never reopen authentication.
        if selection == nil && !busy { loadSelection() }
    }
    private func invalidate() {
        descriptor.text = ""
        recipient.text = ""
        operation?.cancel(); operation = nil; requestID = UUID(); busy = false
    }
    private func render() {
        refresh.isEnabled = !busy && selection != nil
        receive.isEnabled = refresh.isEnabled
        checkRecipient.isEnabled = refresh.isEnabled
        recipient.isEnabled = !busy && selection != nil
        descriptor.isHidden = descriptor.text.isEmpty
        pool.text = selection.map { "Pool: \($0.address.toRaw())\nConfiguration: \($0.sourceDescription)" }
        amount.text = "—"
        switch state {
        case .recipientChecked(let valid):
            status.text = valid ? "Recipient descriptor is valid for this pool." : "Invalid recipient descriptor for this pool."
        case .receipt: status.text = "Share this descriptor with the sender."
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
    private func read(forReceipt: Bool = false, recipientInput: String? = nil) {
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
                else { state = .failed(forReceipt ? "Unable to create a private receiving descriptor." : "Unable to verify your private balance. Refresh to try again.") }
            }
        }
    }
}
