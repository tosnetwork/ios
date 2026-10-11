import UIKit
import KeeperCore
import CoreComponents
import TonSwift

@MainActor
final class TOSPQWalletsViewController: UIViewController {
    private let journal = TOSPQOperationJournal()
    private let store = TOSPQWalletStore.shared
    private let api: API
    private let payer: Wallet
    private let authenticate: () async -> Bool
    private let feeSign: (Cell) async throws -> Data
    private let stack = UIStackView()
    private var session: TOSPQNodeSession?
    private var busy = false
    private var current: TOSPQWalletRecord?
    init(api: API, payer: Wallet, authenticate: @escaping () async -> Bool, feeSign: @escaping (Cell) async throws -> Data) {
        self.api = api; self.payer = payer; self.authenticate = authenticate; self.feeSign = feeSign
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use the PQ wallet assembly") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "PQ Wallets"; view.backgroundColor = .systemBackground
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(conceal), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reveal), name: UIApplication.didBecomeActiveNotification, object: nil)
        refresh()
    }
    @objc private func conceal() { view.isHidden = true }
    @objc private func reveal() { view.isHidden = false }
    private func node() throws -> TOSPQNodeSession {
        guard let session else { throw TOSPQError.invalidInput };return session
    }
    private func clear() { stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() } }
    private func label(_ text: String, id: String? = nil) {
        let label = UILabel();label.text = text;label.accessibilityIdentifier = id;label.numberOfLines = 0;label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true;stack.addArrangedSubview(label)
    }
    private func button(_ title: String, id: String, action: @escaping () -> Void) {
        let button = UIButton(type: .system);var config = UIButton.Configuration.tinted();config.title = title
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12)
        button.configuration = config;button.accessibilityIdentifier = id
        button.addAction(UIAction { [weak self] _ in guard self?.busy == false else { return };action() }, for: .touchUpInside)
        stack.addArrangedSubview(button)
    }
    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy else { return };busy = true
        Task { @MainActor in defer { busy = false };do { try await action() } catch { showError() } }
    }
    private func showError() {
        let alert = UIAlertController(title: "PQ operation unavailable", message: "Check the node, network, device passcode and backup password. No fallback signature was used.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default));present(alert, animated: true)
    }
    private func refresh() { run { [self] in try await loadList() } }
    private func loadList() async throws {
            if session == nil { session = await api.pqSession() }
            let records = try await store.list();clear();current = nil
            let feeAddress = try payer.address.toRaw()
            label("Fee wallet: \(payer.metaData.label)");label(feeAddress, id: "pq.fee.address")
            button("Quantum accounts", id: "pq.quantum") { [weak self] in
                guard let self else { return }
                do { navigationController?.pushViewController(try TOSQuantumWalletsViewController(authenticate: authenticate), animated: true) }
                catch { showError() }
            }
            button("Create PQ wallet", id: "pq.create") { [weak self] in self?.chooseAlgorithm(restore: false) }
            button("Restore encrypted backup", id: "pq.restore") { [weak self] in self?.chooseAlgorithm(restore: true) }
            button("Cryptography licenses", id: "pq.notices") { [weak self] in self?.share(TOSPQSigner.notices) }
            for record in records {
                let address = try record.descriptor().address.toRaw()
                button("\(record.name) · \(record.algorithm == .mldsa44 ? "ML-DSA-44" : "Falcon-512 padded")\n\(address)", id: "pq.wallet.\(record.id)") { [weak self] in self?.detail(record) }
            }
    }
    private func fields(title: String, names: [String], passwords: Set<Int> = [], action: @escaping ([String]) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        for (index, name) in names.enumerated() { alert.addTextField { field in
            field.placeholder = name;field.accessibilityIdentifier = "pq.input.\(index)";field.isSecureTextEntry = passwords.contains(index)
            field.autocapitalizationType = .none;field.autocorrectionType = .no
        } }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in alert.textFields?.forEach { $0.text = nil } })
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in
            let values = alert.textFields?.map { $0.text ?? "" } ?? [];alert.textFields?.forEach { $0.text = nil };action(values)
        });present(alert, animated: true)
    }
    private func chooseAlgorithm(restore: Bool) {
        let alert = UIAlertController(title: restore ? "Restore wallet" : "Create wallet", message: nil, preferredStyle: .alert)
        for algorithm in [TOSPQAlgorithm.mldsa44, .falcon512Padded] {
            alert.addAction(UIAlertAction(title: algorithm == .mldsa44 ? "ML-DSA-44" : "Falcon-512 padded", style: .default) { [weak self] _ in self?.create(algorithm, restore: restore) })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel));present(alert, animated: true)
    }
    private func create(_ algorithm: TOSPQAlgorithm, restore: Bool) {
        fields(title: restore ? "Restore encrypted PQ backup" : "Create PQ wallet",
            names: restore ? ["Wallet name", "Encrypted backup (Base64)", "Backup password"] : ["Wallet name"], passwords: restore ? [2] : []) { [weak self] values in
            self?.run { [weak self] in guard let self else { return }
                let capability = try await node().pqCapabilities();guard capability.version >= UInt32(algorithm.minimumVM), await authenticate() else { throw TOSPQError.invalidInput }
                if restore {
                    guard let data = Data(base64Encoded: values[1]) else { throw TOSPQError.invalidInput }
                    _ = try await store.restore(name: values[0], algorithm: algorithm, network: capability.network, backup: data, password: values[2])
                } else { _ = try await store.create(name: values[0], algorithm: algorithm, network: capability.network) }
                try await loadList()
            }
        }
    }
    private func detail(_ record: TOSPQWalletRecord) {
        do {
            let wallet = try record.descriptor();clear();current = record;label(record.name);label(wallet.address.toRaw())
            button("Back to PQ wallets", id: "pq.back") { [weak self] in self?.refresh() }
            button("Receive / share address", id: "pq.receive") { [weak self] in self?.share(wallet.address.toRaw()) }
            button("Refresh balance and history", id: "pq.history") { [weak self] in self?.run { [weak self] in guard let self else { return }
                try await reconcile(record)
                let account = try await node().pqAccount(address: wallet.address)
                label("Balance: \(Decimal(account.balance) / 1_000_000_000) TOS · \(account.state)")
                if account.state == "active" || account.balance > 0 {
                    for tx in try await node().pqHistory(address: wallet.address) { label("\(Date(timeIntervalSince1970: Double(tx.timestamp)))\n\(tx.hash)") }
                }
            } }
            button("Deploy / fund wallet", id: "pq.deploy") { [weak self] in self?.deploy(record) }
            button("Send TOS", id: "pq.send") { [weak self] in self?.send(record) }
            button("Export encrypted backup", id: "pq.backup") { [weak self] in self?.fields(title: "Encrypt backup", names: ["Password (at least 12 characters)", "Confirm password"], passwords: [0, 1]) { [weak self] values in
                self?.run { [weak self] in guard let self else { return };guard values[0] == values[1], await authenticate() else { throw TOSPQError.invalidInput }
                    let data = try await store.backup(id: record.id, password: values[0]);share(data.base64EncodedString())
                }
            } }
            button("Delete local key", id: "pq.delete") { [weak self] in self?.confirm(title: "Delete \(record.name)?", message: "Funds remain on chain. You need the encrypted PQ backup and its password to restore this wallet.") { [weak self] in
                self?.run { [weak self] in guard let self else { return };guard await authenticate() else { throw TOSPQError.invalidInput }
                    try await store.delete(id: record.id);try await loadList()
                }
            } }
        } catch { showError() }
    }
    private func amount(_ raw: String) throws -> UInt64 {
        guard raw.range(of: "^[0-9]+(\\.[0-9]{1,9})?$", options: .regularExpression) != nil else { throw TOSPQError.invalidInput }
        let pieces = raw.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = pieces.count == 2 ? String(pieces[1]) : ""
        guard let value = UInt64(String(pieces[0]) + fraction + String(repeating: "0", count: 9 - fraction.count)), value > 0, value <= Int64.max else { throw TOSPQError.invalidInput }
        return value
    }
    private func deploy(_ record: TOSPQWalletRecord) {
        fields(title: "Deploy \(record.name)", names: ["Verifier funding (TOS)", "PQ wallet funding (TOS)"]) { [weak self] values in guard let self else { return }
            do {
                let root = try amount(values[0]), funding = try amount(values[1]);let (total, overflow) = root.addingReportingOverflow(funding)
                guard !overflow else { throw TOSPQError.invalidInput }
                confirm(title: "Confirm deployment", message: "Fee wallet pays \(values[0]) TOS to the verifier and \(values[1]) TOS to this PQ wallet, plus network fees. The verifier deposit is reserved for storage and cannot be withdrawn.") { [weak self] in self?.run { [weak self] in guard let self else { return }
                    let relay = TOSPQRelay(wallet: try record.descriptor())
                    try await transport(record, relay: relay, plan: relay.deployment(moduleFunding: root, walletFunding: funding), funding: total)
                } }
            } catch { showError() }
        }
    }
    private func send(_ record: TOSPQWalletRecord) {
        fields(title: "Send from \(record.name)", names: ["Recipient address", "Amount (TOS)", "Comment", "Fee transport funding (TOS)"]) { [weak self] values in guard let self else { return }
            do {
                let destination = try Address.parse(values[0]), coins = try amount(values[1]), funding = try amount(values[3])
                confirm(title: "Confirm PQ transfer", message: "\(values[1]) TOS to \(destination.toRaw())\nComment: \(values[2])\nFee wallet pays \(values[3]) TOS to the verifier, plus network fees.") { [weak self] in self?.run { [weak self] in guard let self else { return }
                    try await ensureResolved(record)
                    let wallet = try record.descriptor(), snapshot = try await node().pqSnapshot(wallet: wallet)
                    guard snapshot.chainTime <= UInt32.max - 600, snapshot.balance > coins, await authenticate() else { throw TOSPQError.invalidInput }
                    let request = try wallet.request(epoch: snapshot.epoch, nonce: snapshot.nonce, validUntil: snapshot.chainTime + 600, now: snapshot.chainTime,
                        payload: wallet.transferPayload(destination: destination, nanotomi: coins, comment: values[2]))
                    let signature = try await store.sign(id: record.id, message: wallet.signingMessage(request: request))
                    let fresh = try await node().pqSnapshot(wallet: wallet)
                    guard fresh.epoch == snapshot.epoch, fresh.nonce == snapshot.nonce else { throw TOSPQError.keyBinding }
                    let relay = TOSPQRelay(wallet: wallet)
                    try await transport(record, relay: relay, plan: relay.submission(request: request, signature: signature, funding: funding), funding: funding, expected: snapshot, recipient: destination.toRaw(), amount: coins)
                } }
            } catch { showError() }
        }
    }
    private func transport(_ record: TOSPQWalletRecord, relay: TOSPQRelay, plan: TOSPQRelayPlan, funding: UInt64, expected: TOSPQSnapshot? = nil, recipient: String? = nil, amount: UInt64 = 0) async throws {
        try await ensureResolved(record)
        let capabilities = try await node().pqCapabilities()
        guard capabilities.network == record.network, capabilities.version >= UInt32(record.algorithm.minimumVM) else { throw TOSPQError.keyBinding }
        let snapshot = try await node().pqFeeSnapshot(payer: payer, expectedNetwork: record.network)
        guard snapshot.chainTime <= UInt32.max - 600, snapshot.balance > funding else { throw TOSPQError.invalidInput }
        let unsigned = try relay.feeSigningMessage(plan: plan, network: record.network, seqno: snapshot.seqno, now: snapshot.chainTime, validUntil: snapshot.chainTime + 600)
        let fees = try await node().pqEstimateFee(payer: payer, unsigned: unsigned, snapshot: snapshot)
        let (cost, overflow) = funding.addingReportingOverflow(fees)
        guard !overflow, snapshot.balance > cost, await reviewFees(funding: funding, fees: fees) else { throw TOSPQError.invalidInput }
        let signature = try await feeSign(unsigned)
        let fresh = try await node().pqFeeSnapshot(payer: payer, expectedNetwork: record.network)
        guard fresh.seqno == snapshot.seqno, fresh.chainTime < snapshot.chainTime + 600 else { throw TOSPQError.keyBinding }
        if let expected {
            let current = try await node().pqSnapshot(wallet: record.descriptor())
            guard current.epoch == expected.epoch, current.nonce == expected.nonce, current.chainTime < expected.chainTime + 600 else { throw TOSPQError.keyBinding }
        }
        let body = try Builder().store(slice: unsigned.beginParse()).store(data: signature).endCell()
        let external = try Message.external(to: payer.address, stateInit: snapshot.seqno == 0 ? payer.contract.stateInit : nil, body: body)
        let externalCell = try Builder().store(external).endCell()
        let boc = try externalCell.toBoc().base64EncodedString()
        let wallet = try record.descriptor()
        try await journal.write(TOSPQPendingOperation(feeAddress: payer.address.toRaw(), externalHash: externalCell.hash().base64EncodedString(), moduleAddress: wallet.moduleAddress.toRaw(), walletAddress: wallet.address.toRaw(), recipient: recipient, amount: amount, seqno: snapshot.seqno, expires: snapshot.chainTime + 600))
        try await node().pqBroadcast(boc: boc, expectedNetwork: record.network, minimumVM: record.algorithm.minimumVM)
        label("Submitted. Awaiting chain confirmation; check balance and history before retrying.")
    }
    private func ensureResolved(_ record: TOSPQWalletRecord) async throws {
        let address = try record.descriptor().address.toRaw()
        guard let pending = try await journal.read(address: address) else { return }
        if !pending.status.terminal { try await reconcile(record) }
        guard try await journal.read(address: address)?.status.terminal == true else { throw TOSPQError.invalidInput }
    }
    private func reconcile(_ record: TOSPQWalletRecord) async throws {
        let wallet = try record.descriptor()
        guard var pending = try await journal.read(address: wallet.address.toRaw()) else { return }
        let capabilities = try await node().pqCapabilities()
        guard capabilities.network == record.network, capabilities.version >= UInt32(record.algorithm.minimumVM) else { throw TOSPQError.keyBinding }
        var status = try await node().pqReconcile(pending, wallet: wallet)
        if status == .pending, pending.feeAddress == (try payer.address.toRaw()) {
            let snapshot = try await node().pqFeeSnapshot(payer: payer, expectedNetwork: record.network)
            if snapshot.seqno == pending.seqno, snapshot.chainTime > pending.expires { status = .expired }
        }
        pending.status = status;try await journal.write(pending);label("Submission: \(status.rawValue) (selected-node receipts).")
    }
    private func reviewFees(funding: UInt64, fees: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: "Review network fees", message: "Fee wallet funding: \(Decimal(funding) / 1_000_000_000) TOS\nEstimated fee for fee-wallet submission: \(Decimal(fees) / 1_000_000_000) TOS. Verifier and PQ-wallet execution fees are paid from the funding and balances. Unused transfer funding is credited to the PQ wallet. Actual network fees may vary.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Confirm", style: .default) { _ in continuation.resume(returning: true) })
            present(alert, animated: true)
        }
    }
    private func confirm(title: String, message: String, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel));alert.addAction(UIAlertAction(title: "Confirm", style: .default) { _ in action() });present(alert, animated: true)
    }
    private func share(_ value: String) {
        let share = UIActivityViewController(activityItems: [value], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = view;share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(share, animated: true)
    }
}
