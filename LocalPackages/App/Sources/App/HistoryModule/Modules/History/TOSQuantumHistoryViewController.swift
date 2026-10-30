import UIKit
import KeeperCore
import TKCoordinator
import TKLocalize

/// The product history route for Quantum wallets. Only the current 20 records
/// and 128 small pagination capabilities are retained; raw RPC events are unused.
@MainActor
final class TOSQuantumHistoryViewController: UIViewController, @preconcurrency ScrollViewController, @preconcurrency TokenDetailsListContentViewController, UITableViewDataSource, UITableViewDelegate {
    private let wallet: Wallet
    private let embedded: Bool
    private let heading = UIStackView()
    private let headerContainer = UIView()
    private var tokenHeader: UIViewController?
    var scrollView: UIScrollView { table }
    var didPullToRefresh: (() -> Void)?
    var didRequestPendingPayment: (() -> Void)?
    var didRequestReceive: (() -> Void)?
    var didRequestConfigureRPC: (() -> Void)?
    private let service = TOSQuantumHistoryService()
    private let dateFormatter: DateFormatter = {
        let value = DateFormatter(); value.dateStyle = .medium; value.timeStyle = .short; return value
    }()
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let status = UILabel()
    private let newest = UIButton(type: .system)
    private let previous = UIButton(type: .system)
    private let older = UIButton(type: .system)
    private let configureRPC = UIButton(type: .system)
    private var records = [TOSQuantumHistoryRecord]()
    private var starts: [TOSQuantumHistoryService.Cursor?] = [nil]
    private var pageIndex = 0
    private var nextCursor: TOSQuantumHistoryService.Cursor?
    private var operation: Task<Void, Never>?
    private var requestID = UUID()

    init(wallet: Wallet, embedded: Bool = false) {
        self.wallet = wallet; self.embedded = embedded; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }
    deinit { operation?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel(); title.text = TKLocales.History.title
        title.font = .preferredFont(forTextStyle: .largeTitle); title.adjustsFontForContentSizeCategory = true
        let name = UILabel(); name.text = wallet.label; name.font = .preferredFont(forTextStyle: .body)
        name.adjustsFontForContentSizeCategory = true; name.numberOfLines = 2
        status.numberOfLines = 0; status.font = .preferredFont(forTextStyle: .footnote)
        status.adjustsFontForContentSizeCategory = true; status.accessibilityIdentifier = "quantum.history.status"
        configure(newest, title: "Refresh", id: "newest") { [weak self] in self?.load(index: 0, reset: true) }
        configure(previous, title: "Newer", id: "previous") { [weak self] in
            guard let self, pageIndex > 0 else { return }; load(index: pageIndex - 1)
        }
        configure(older, title: "Older", id: "older") { [weak self] in
            guard let self, let nextCursor else { return }
            load(index: pageIndex + 1, continuation: nextCursor)
        }
        let buttons = UIStackView(arrangedSubviews: [newest, previous, older]); buttons.distribution = .fillEqually
        let savedPayment = UIButton(type: .system)
        configure(savedPayment, title: "Saved payment", id: "payment") { [weak self] in self?.didRequestPendingPayment?() }
        savedPayment.isHidden = didRequestPendingPayment == nil
        let receive = UIButton(type: .system)
        configure(receive, title: "Receive TOS", id: "receive") { [weak self] in self?.didRequestReceive?() }
        receive.isHidden = didRequestReceive == nil
        configure(configureRPC, title: "Configure TOS node", id: "configureRPC") { [weak self] in self?.didRequestConfigureRPC?() }
        configureRPC.isHidden = true
        let items: [UIView] = embedded ? [status, configureRPC, savedPayment, receive, buttons] : [title, name, status, configureRPC, savedPayment, receive, buttons]
        items.forEach(heading.addArrangedSubview); heading.axis = .vertical; heading.spacing = 8
        heading.translatesAutoresizingMaskIntoConstraints = false
        table.translatesAutoresizingMaskIntoConstraints = false; table.dataSource = self; table.delegate = self
        table.accessibilityIdentifier = "quantum.history.records"
        table.refreshControl = UIRefreshControl()
        table.refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        headerContainer.addSubview(heading); table.tableHeaderView = headerContainer
        view.addSubview(table)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 12),
            heading.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -20),
            heading.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -12),
            table.topAnchor.constraint(equalTo: embedded ? view.topAnchor : view.safeAreaLayoutGuide.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor), table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        load(index: 0, reset: true)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = table.bounds.width
        guard width > 40 else { return }
        let size = heading.systemLayoutSizeFitting(CGSize(width: width - 40, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = ceil(size.height + 24)
        if headerContainer.bounds.width != width || abs(headerContainer.bounds.height - height) > 0.5 {
            headerContainer.frame = CGRect(x: 0, y: 0, width: width, height: height)
            table.tableHeaderView = headerContainer
        }
    }
    func setHeaderViewController(_ controller: UIViewController?) {
        guard tokenHeader !== controller else { return }
        tokenHeader?.willMove(toParent: nil); tokenHeader?.view.removeFromSuperview(); tokenHeader?.removeFromParent()
        tokenHeader = controller
        guard let controller else { return }
        loadViewIfNeeded(); addChild(controller); controller.view.translatesAutoresizingMaskIntoConstraints = false
        heading.insertArrangedSubview(controller.view, at: 0); controller.didMove(toParent: self)
        view.setNeedsLayout()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A tab change may have cancelled the initial read before any rows arrived.
        if records.isEmpty && operation == nil { load(index: 0, reset: true) }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        requestID = UUID(); operation?.cancel(); operation = nil
        table.refreshControl?.endRefreshing()
    }
    func scrollToTop() { table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: true) }
    func refreshAfterRPCConfigurationChange() { load(index: 0, reset: true) }
    @objc private func refresh() { didPullToRefresh?(); load(index: 0, reset: true) }

    private func configure(_ button: UIButton, title: String, id: String, action: @escaping () -> Void) {
        var config = UIButton.Configuration.tinted(); config.title = title
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 6, bottom: 12, trailing: 6)
        button.configuration = config; button.accessibilityIdentifier = "quantum.history." + id
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
    private func load(index: Int, reset: Bool = false, continuation: TOSQuantumHistoryService.Cursor? = nil) {
        guard operation == nil else { table.refreshControl?.endRefreshing(); return }
        let cursor: TOSQuantumHistoryService.Cursor?
        if reset { cursor = nil }
        else if let continuation { cursor = continuation }
        else { guard starts.indices.contains(index) else { return }; cursor = starts[index] }
        let id = UUID(); requestID = id
        records = []; table.reloadData(); status.text = "Verifying history…"
        configureRPC.isHidden = true
        newest.isEnabled = false; previous.isEnabled = false; older.isEnabled = false
        let service = service, wallet = wallet
        operation = Task { [weak self] in
            do {
                var loaded: TOSQuantumHistoryService.Page?
                // A balance refresh can briefly own the same bounded proof reader.
                // Retry a fixed number of times; no queue or stale result is used.
                for attempt in 0..<3 {
                    do { loaded = try await service.read(wallet: wallet, cursor: cursor); break }
                    catch TOSQuantumHistoryService.ReadError.busy {
                        try Task.checkCancellation()
                        if attempt == 2 { throw TOSQuantumHistoryService.ReadError.busy }
                        try await Task.sleep(nanoseconds: 300_000_000)
                    }
                }
                guard let page = loaded else { throw CancellationError() }
                try Task.checkCancellation()
                guard let self, requestID == id else { return }
                if reset { starts = [nil]; pageIndex = 0 }
                else {
                    if index == starts.count { starts.append(cursor) }
                    pageIndex = index
                    if starts.count > 128 { starts.removeFirst(); pageIndex -= 1 }
                }
                records = page.records; nextCursor = page.next
                let date = dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(page.checkpointTime)))
                status.text = records.isEmpty ? "No transactions. Verified through \(date)." : "Verified through \(date)"
                configureRPC.isHidden = true
                finish(); table.reloadData(); scrollToTop()
            } catch {
                guard let self, requestID == id else { return }
                records = []; starts = [nil]; pageIndex = 0; nextCursor = nil
                status.text = "Unable to verify history. Refresh to try again."
                configureRPC.isHidden = false
                finish(); table.reloadData()
            }
        }
    }
    private func finish() {
        operation = nil; table.refreshControl?.endRefreshing()
        newest.isEnabled = true; previous.isEnabled = pageIndex > 0; older.isEnabled = nextCursor != nil
        view.setNeedsLayout()
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { records.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard records.indices.contains(indexPath.row) else { return cell }
        let record = records[indexPath.row]
        var content = cell.defaultContentConfiguration()
        let message: TOSQuantumHistoryRecord.Message?
        switch record.direction {
        case .incoming:
            content.text = record.inbound?.bounced == true ? "Returned transfer" : "Incoming transfer"
            message = record.inbound
        case .outgoing:
            content.text = "Outgoing transfer"
            let candidates = record.outbound.filter { $0.kind == .internalMessage && !$0.bounced }
            message = candidates.count == 1 ? candidates.first : nil
        case .operation: content.text = "Wallet operation"; message = nil
        }
        let amount = message?.amountNano.flatMap(TOSQuantumHistoryRecord.formatNano)
        let assets = message?.otherCurrencies == true ? " + other assets" : ""
        content.secondaryText = [amount.map { $0 + assets }, Self.outcome(record.outcome), dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(record.timestamp)))].compactMap { $0 }.joined(separator: "\n")
        content.secondaryTextProperties.numberOfLines = 0; content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content; cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "quantum.history.record." + record.hash
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard records.indices.contains(indexPath.row) else { return }
        let detail = TOSQuantumHistoryDetailViewController(record: records[indexPath.row])
        present(UINavigationController(rootViewController: detail), animated: true)
    }
    fileprivate static func outcome(_ value: TOSQuantumHistoryRecord.Outcome) -> String {
        switch value {
        case .included: return "Included"
        case .executed: return "Executed"
        case .sendSkipped: return "Send skipped"
        case .executionFailed: return "Execution did not succeed"
        }
    }
}

@MainActor
private final class TOSQuantumHistoryDetailViewController: UITableViewController {
    private let record: TOSQuantumHistoryRecord
    private var rows: [(String, String)] = []
    init(record: TOSQuantumHistoryRecord) { self.record = record; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Transaction"
        let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        done.accessibilityIdentifier = "quantum.history.detail.done"
        navigationItem.rightBarButtonItem = done
        rows = [("Status", TOSQuantumHistoryViewController.outcome(record.outcome)), ("Transaction hash", record.hash),
            ("Logical time", record.logicalTime), ("Timestamp", ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(record.timestamp)))), ("Account", record.account),
            ("Transaction fee", (TOSQuantumHistoryRecord.formatNano(record.feesNano) ?? "Unavailable") + (record.otherFeeCurrencies ? " + other assets" : ""))]
        if record.skippedActions > 0 { rows.append(("Skipped actions", String(record.skippedActions))) }
        let messages = record.inbound.map { [$0] } ?? []
        for (index, message) in (messages + record.outbound).enumerated() {
            let label = index == 0 && record.inbound != nil ? "Incoming" : "Outgoing"
            if let source = message.source { rows.append((label + " from", source)) }
            if let destination = message.destination { rows.append((label + " to", destination)) }
            if let value = message.amountNano, let amount = TOSQuantumHistoryRecord.formatNano(value) {
                rows.append((label + " amount", amount + (message.otherCurrencies ? " + other assets" : "")))
            }
        }
        tableView.accessibilityIdentifier = "quantum.history.detail"
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration(); content.text = rows[indexPath.row].0
        content.secondaryText = rows[indexPath.row].1; content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        return cell
    }
}
