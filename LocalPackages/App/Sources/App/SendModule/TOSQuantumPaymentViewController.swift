import UIKit
import KeeperCore
import CoreComponents
import TonSwift
import BigInt
import TKLogging

/// Dedicated native-coin flow. Signing consent and final fee confirmation are
/// separate actions. A relay response never becomes a successful payment.
@MainActor
final class TOSQuantumPaymentViewController: UIViewController {
    private let wallet: Wallet
    private let authenticate: @MainActor () async -> Bool
    private let recipientResolver: RecipientResolver
    private let initialRecipient: TonRecipient?
    private var requiresComment: Bool
    private var flaggedRecipient: Bool
    private var lastResolvedAddress: Address?
    private let warningRow = UIStackView(), commentTitle = UILabel()
    private let recipient = UITextField(), amount = UITextField(), comment = UITextView()
    private let bounce = UISwitch(), acknowledge = UISwitch()
    private let status = UILabel(), details = UILabel()
    private let review = UIButton(type: .system), sign = UIButton(type: .system)
    private let send = UIButton(type: .system), refreshQuote = UIButton(type: .system)
    private let verify = UIButton(type: .system), older = UIButton(type: .system)
    private let reload = UIButton(type: .system), edit = UIButton(type: .system), discard = UIButton(type: .system)
    private var coordinator: TOSQuantumPaymentCoordinator?
    private let preparation = TOSQuantumPaymentService()
    private var pending: TOSQuantumOutbox.Entry?
    private var prepared: TOSQuantumPreparedPayment?
    private var quote: TOSQuantumPaymentQuote?
    private var cursor: TOSQuantumPaymentOutcomeReader.Cursor?
    private var operation: Task<Void, Never>?
    private var requestID = UUID()
    private var busy = false, emptyJournal = false, authenticated = false
    private var reloadOnAppearance = true

    init(wallet: Wallet, amount initialAmount: BigUInt, recipient initialRecipient: TonRecipient?,
         comment initialComment: String?, recipientResolver: RecipientResolver,
         authenticate: @escaping @MainActor () async -> Bool) {
        self.wallet = wallet; self.authenticate = authenticate; self.recipientResolver = recipientResolver
        self.initialRecipient = initialRecipient
        requiresComment = initialRecipient?.isMemoRequired == true
        flaggedRecipient = initialRecipient?.isScam == true
        super.init(nibName: nil, bundle: nil)
        recipient.text = initialRecipient?.recipientAddress.addressString
        bounce.isOn = initialRecipient?.recipientAddress.isBouncable ?? false
        if initialAmount > 0, let formatted = TOSQuantumHistoryRecord.formatNano(String(initialAmount)) {
            amount.text = String(formatted.dropLast(4))
        }
        comment.text = initialComment
    }
    required init?(coder: NSCoder) { return nil }
    deinit { operation?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad(); title = "Quantum payment"; view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        func label(_ text: String) -> UILabel {
            let value = UILabel(); value.text = text; value.numberOfLines = 0
            value.font = .preferredFont(forTextStyle: .body); value.adjustsFontForContentSizeCategory = true; return value
        }
        stack.addArrangedSubview(label("Keep your wallet recovery secrets safely backed up before funding or sending. Public account details cannot restore signing keys."))
        for (field, text, id) in [(recipient, "Full recipient address", "recipient"), (amount, "Amount (TOS)", "amount")] {
            field.borderStyle = .roundedRect; field.placeholder = text; field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true; field.autocorrectionType = .no; field.autocapitalizationType = .none
            field.accessibilityIdentifier = "quantum.payment." + id; stack.addArrangedSubview(field)
        }
        amount.keyboardType = .decimalPad; recipient.keyboardType = .asciiCapable
        commentTitle.font = .preferredFont(forTextStyle: .body); commentTitle.adjustsFontForContentSizeCategory = true
        commentTitle.text = requiresComment ? "Comment (required)" : "Comment (optional)"; stack.addArrangedSubview(commentTitle)
        comment.font = .preferredFont(forTextStyle: .body); comment.adjustsFontForContentSizeCategory = true
        comment.layer.borderWidth = 1; comment.layer.borderColor = UIColor.separator.cgColor; comment.layer.cornerRadius = 8
        comment.accessibilityIdentifier = "quantum.payment.comment"; comment.heightAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        stack.addArrangedSubview(comment)
        let bounceRow = UIStackView(arrangedSubviews: [label("Return funds if recipient cannot accept"), bounce]); stack.addArrangedSubview(bounceRow)
        bounce.accessibilityIdentifier = "quantum.payment.bounce"
        warningRow.addArrangedSubview(label("This recipient is flagged as potentially unsafe. I understand the risk."))
        warningRow.addArrangedSubview(acknowledge); warningRow.isHidden = !flaggedRecipient
        acknowledge.accessibilityIdentifier = "quantum.payment.acknowledge"
        acknowledge.addTarget(self, action: #selector(acknowledgmentChanged), for: .valueChanged)
        stack.addArrangedSubview(warningRow)
        for (item, id) in [(details, "details"), (status, "status")] {
            item.font = .preferredFont(forTextStyle: .body); item.adjustsFontForContentSizeCategory = true
            item.numberOfLines = 0; item.accessibilityIdentifier = "quantum.payment." + id; stack.addArrangedSubview(item)
        }
        configure(review, "Review payment", "review") { [weak self] in self?.prepare() }
        configure(sign, "Sign and estimate locally", "sign") { [weak self] in self?.authorize() }
        configure(send, "Confirm fee and send", "send") { [weak self] in self?.submit() }
        configure(refreshQuote, "Re-estimate saved payment", "estimate") { [weak self] in self?.recoverEstimate() }
        configure(verify, "Verify payment result", "verify") { [weak self] in self?.verifyResult(continuing: false) }
        configure(older, "Check older transactions", "older") { [weak self] in self?.verifyResult(continuing: true) }
        configure(edit, "Edit unsigned payment", "edit") { [weak self] in
            guard let self else { return }; prepared = nil; quote = nil; authenticated = false; details.text = nil; render()
        }
        configure(discard, "Discard unsigned request", "discard") { [weak self] in self?.confirmDiscard() }
        configure(reload, "Reload saved payment", "reload") { [weak self] in self?.loadJournal() }
        [review, sign, send, refreshQuote, verify, older, edit, discard, reload].forEach(stack.addArrangedSubview)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foregrounded), name: UIApplication.didBecomeActiveNotification, object: nil)
        do { coordinator = try TOSQuantumPaymentCoordinator() }
        catch { status.text = "Wallet storage is unavailable. Reload before preparing another payment." }
        render()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if reloadOnAppearance && !busy { reloadOnAppearance = false; loadJournal() }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // A full-screen passcode presentation must not cancel its own action.
        if isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent { invalidate() }
    }
    @objc private func close() {
        invalidate()
        if navigationController?.viewControllers.first === self { dismiss(animated: true) }
        else { navigationController?.popViewController(animated: true) }
    }
    @objc private func backgrounded() { invalidate(); reloadOnAppearance = true }
    @objc private func foregrounded() {
        guard reloadOnAppearance, isViewLoaded, view.window != nil, !busy else { return }
        reloadOnAppearance = false; loadJournal()
    }
    @objc private func acknowledgmentChanged() { render() }
    private func invalidate() {
        operation?.cancel(); operation = nil; requestID = UUID(); busy = false
        authenticated = false; quote = nil; prepared = nil; emptyJournal = false; cursor = nil; render()
    }
    private func configure(_ button: UIButton, _ title: String, _ id: String, _ action: @escaping () -> Void) {
        var config = UIButton.Configuration.tinted(); config.title = title
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12)
        button.configuration = config; button.accessibilityIdentifier = "quantum.payment." + id
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
    private func render() {
        let editable = !busy && emptyJournal && prepared == nil && pending == nil
        recipient.isEnabled = editable; amount.isEnabled = editable; comment.isEditable = editable; bounce.isEnabled = editable
        acknowledge.isEnabled = !busy && (editable || pending?.phase == .signed)
        review.isHidden = pending != nil || prepared != nil; review.isEnabled = editable
        sign.isHidden = prepared == nil || pending != nil; sign.isEnabled = !busy && wallet.isSendEnable
        send.isHidden = quote == nil; send.isEnabled = !busy && authenticated && wallet.isSendEnable && (!flaggedRecipient || acknowledge.isOn)
        refreshQuote.isHidden = pending?.phase != .signed || pending?.paymentIntent == nil
        refreshQuote.isEnabled = !busy && wallet.isSendEnable
        verify.isHidden = pending?.signedBOC == nil || pending?.paymentIntent == nil; verify.isEnabled = !busy
        older.isHidden = cursor == nil; older.isEnabled = !busy
        edit.isHidden = prepared == nil || pending != nil; edit.isEnabled = !busy
        discard.isHidden = pending?.phase != .reserved; discard.isEnabled = !busy
        reload.isEnabled = !busy
        isModalInPresentation = busy
        if !wallet.isSendEnable && (prepared != nil || quote != nil) {
            status.text = "Payment sending is not available yet. Your reviewed payment has not been sent."
        }
    }
    private func run(_ message: String, _ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; status.text = message
        let id = UUID(); requestID = id; render()
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if requestID == id { operation = nil; busy = false; render() } }
            do { try Task.checkCancellation(); try await work(); try Task.checkCancellation() }
            catch {
                record(error)
                guard requestID == id else { return }
                quote = nil; prepared = nil; authenticated = false; emptyJournal = false
                status.text = "Unable to complete this action. Any saved authorization is retained. Reload or verify its result."
            }
        }
    }
    private func record(_ error: Swift.Error) {
        var info: [String: String] = ["type": String(describing: type(of: error)), "code": String((error as NSError).code)]
        if case TOSPQError.keychain(let status) = error { info["keychainStatus"] = String(status) }
        // Never log the request, signature, protected record, or secret material.
        Log.e("Quantum payment action failed", extraInfo: info)
    }
    private func show(_ intent: TOSQuantumPaymentIntent) {
        details.text = "Recipient: \(intent.recipient.toRaw())\nAmount: \(TOSQuantumHistoryRecord.formatNano(String(intent.amount)) ?? String(intent.amount))\nReturn on rejection: \(intent.bounce ? "Yes" : "No")\nComment: \(intent.comment ?? "None")"
    }
    private func loadJournal() {
        run("Loading saved payment…") { [self] in
            if coordinator == nil { coordinator = try TOSQuantumPaymentCoordinator() }
            guard let coordinator else { return }
            let value = try await coordinator.pending(wallet: wallet)
            try Task.checkCancellation()
            pending = value; emptyJournal = value == nil; prepared = nil; quote = nil; authenticated = false; cursor = nil
            if let value {
                if let intent = value.paymentIntent {
                    recipient.text = intent.recipient.toRaw()
                    if let formatted = TOSQuantumHistoryRecord.formatNano(String(intent.amount)) { amount.text = String(formatted.dropLast(4)) }
                    comment.text = intent.comment; bounce.isOn = intent.bounce; show(intent)
                }
                else { details.text = "A wallet authorization is already pending." }
                status.text = value.signedBOC == nil ? "Authorization saved before signing completed. It cannot be replaced automatically." : "Saved payment. Verify its result or re-estimate the same signed message."
            } else { details.text = nil; status.text = "Enter the recipient and exact amount to review." }
        }
    }
    private func prepare() {
        view.endEditing(true)
        guard emptyJournal, pending == nil else { return }
        do {
            let text = (recipient.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let address = try Address.parse(text)
            if let friendly = try? FriendlyAddress(string: text) {
                guard !friendly.isTestOnly || wallet.network == .testnet else { throw TOSPQError.invalidInput }
                bounce.isOn = friendly.isBounceable
            }
            let value = try TOSQuantumPaymentIntent.parseAmount((amount.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            let body = comment.text ?? ""
            let selectedBounce = bounce.isOn
            run("Verifying recipient, account and payment…") { [self] in
                guard try await validateRecipient(text, expected: address, body: body) else { return }
                let intent = try TOSQuantumPaymentIntent(recipient: address, amount: value, bounce: selectedBounce, comment: body)
                let value = try await preparation.prepare(wallet: wallet, intent: intent)
                try Task.checkCancellation(); prepared = value; show(value.intent)
                details.text = (details.text ?? "") + "\nWallet deployment: \(value.requiresDeployment ? "Required, paid by this wallet" : "Already deployed")"
                status.text = "Review these details. Signing and estimating locally will not broadcast."
            }
        } catch {
            status.text = "Check the full address, positive TOS amount (at most 9 decimal places), required comment and recipient warning. Comments are limited to 4096 UTF-8 bytes."
        }
    }
    private func validateRecipient(_ text: String, expected: Address, body: String) async throws -> Bool {
        let resolved = try await recipientResolver.resolverTonRecipient(string: text, network: wallet.network)
        try Task.checkCancellation()
        guard resolved.recipientAddress.address == expected else { throw TOSPQError.keyBinding }
        if case .domain = resolved.recipientAddress { throw TOSPQError.keyBinding }
        if lastResolvedAddress != expected { acknowledge.isOn = false; lastResolvedAddress = expected }
        let originalMatches = initialRecipient?.recipientAddress.address == expected
        requiresComment = resolved.isMemoRequired || (originalMatches && initialRecipient?.isMemoRequired == true)
        flaggedRecipient = resolved.isScam || (originalMatches && initialRecipient?.isScam == true)
        commentTitle.text = requiresComment ? "Comment (required)" : "Comment (optional)"
        warningRow.isHidden = !flaggedRecipient
        if requiresComment && body.isEmpty {
            status.text = "This recipient requires a comment. A saved signed message cannot be edited or replaced automatically."
            return false
        }
        if flaggedRecipient && !acknowledge.isOn {
            status.text = "Review and acknowledge the recipient warning before proceeding."
            return false
        }
        return true
    }
    private func authorize() {
        guard wallet.isSendEnable, let prepared, pending == nil, let coordinator else { return }
        run("Authenticate to sign and estimate locally…") { [self] in
            let approved = await authenticate(); try Task.checkCancellation()
            guard approved else { status.text = "Authentication cancelled. Nothing was signed or sent."; return }
            authenticated = true
            let value = try await coordinator.authorizeAndEstimate(prepared)
            try Task.checkCancellation(); let saved = try await coordinator.pending(wallet: wallet)
            try Task.checkCancellation(); pending = saved; showQuote(value)
        }
    }
    private func showQuote(_ value: TOSQuantumPaymentQuote) {
        quote = value; show(value.intent)
        details.text = (details.text ?? "") + "\nEstimated fee: \(TOSQuantumHistoryRecord.formatNano(String(value.estimatedFee)) ?? String(value.estimatedFee))\nEstimated total debit: \(TOSQuantumHistoryRecord.formatNano(String(value.estimatedDebit)) ?? String(value.estimatedDebit))\nEstimate expires: \(Date(timeIntervalSince1970: TimeInterval(value.expiresAt)).formatted())"
        status.text = "Not sent. Confirm this estimated fee to send the saved signed message. Fees are an estimate."
    }
    private func recoverEstimate() {
        guard wallet.isSendEnable, pending?.phase == .signed, let coordinator else { return }
        run("Checking the saved recipient…") { [self] in
            guard let intent = pending?.paymentIntent,
                  try await validateRecipient(intent.recipient.toRaw(), expected: intent.recipient, body: intent.comment ?? "") else { return }
            let approved = await authenticate(); try Task.checkCancellation()
            guard approved else { status.text = "Authentication cancelled. Saved authorization retained."; return }
            authenticated = true
            let value = try await coordinator.recoverAndEstimate(wallet: wallet)
            try Task.checkCancellation(); showQuote(value)
        }
    }
    private func submit() {
        guard wallet.isSendEnable, authenticated, !flaggedRecipient || acknowledge.isOn,
              let quote, let coordinator else { return }
        guard Int64(Date().timeIntervalSince1970) < Int64(quote.expiresAt) else {
            self.quote = nil; authenticated = false; status.text = "Estimate expired. Re-estimate the saved payment."; render(); return
        }
        run("Submitting the saved signed message…") { [self] in
            do { try await coordinator.submit(quote) }
            catch {
                record(error)
                // A cancelled, superseded task cannot overwrite a newer screen.
                try Task.checkCancellation()
                self.quote = nil; authenticated = false
                status.text = "Submission outcome is unknown. Verify the result before another payment."
                return
            }
            try Task.checkCancellation(); self.quote = nil; authenticated = false
            let saved = try await coordinator.pending(wallet: wallet)
            try Task.checkCancellation(); pending = saved
            status.text = "Submission outcome is unknown. Verify the result; relay acceptance is not payment confirmation."
        }
    }
    private func verifyResult(continuing: Bool) {
        let start = continuing ? cursor : nil
        run("Verifying the saved payment result…") { [self] in
            let reader = try TOSQuantumPaymentOutcomeReader()
            let page = try await reader.read(wallet: wallet, cursor: start)
            try Task.checkCancellation(); cursor = page.next
            if let receipt = page.receipt {
                show(receipt.intent)
                let hash = receipt.transactionHash.map { String(format: "%02x", $0) }.joined()
                details.text = (details.text ?? "") + "\nTransaction: \(hash)\nLogical time: \(receipt.logicalTime)"
                status.text = receipt.outcome == .senderSent ? "Verified: this wallet sent the exact transfer. Recipient credit is not verified here. The authorization remains saved." : "The exact request was included, but this transaction did not confirm the exact transfer. Authorization retained."
            } else {
                status.text = page.authorizationExpired ? "Authorization expired according to verified chain time. Payment outcome is unverified; authorization retained." : "Payment outcome is unverified. Authorization retained."
            }
        }
    }
    private func confirmDiscard() {
        guard let entry = pending, entry.phase == .reserved else { return }
        let alert = UIAlertController(title: "Discard unsigned request?", message: "Only a request that has never reached signing can be discarded.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep", style: .cancel))
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
            guard let self, let coordinator else { return }
            run("Discarding unsigned request…") { [self] in
                try await coordinator.cancelUnsigned(wallet: self.wallet, operationID: entry.id)
                try Task.checkCancellation(); self.pending = nil; self.prepared = nil; self.quote = nil; self.emptyJournal = true; self.details.text = nil
                self.status.text = "Unsigned request discarded. No signed authorization was released."
            }
        })
        present(alert, animated: true)
    }
}
