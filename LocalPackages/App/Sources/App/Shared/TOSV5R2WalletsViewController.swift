import UIKit
import KeeperCore
import CoreComponents
import TonSwift

/// Initial account access. Current chain verification and funded recovery remain separate workflow stages.
@MainActor
final class TOSV5R2WalletsViewController: UIViewController {
    private let store: TOSV5R2WalletStore
    private let stack = UIStackView()
    private var operation: Task<Void, Never>?
    private var busy = false
    init(authenticate: @escaping @MainActor () async -> Bool) throws {
        store = try TOSV5R2WalletStore(authenticate: authenticate)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "V5R2 accounts"; view.backgroundColor = .systemBackground
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(conceal), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reveal), name: UIApplication.didBecomeActiveNotification, object: nil)
        refresh()
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); operation?.cancel() }
    @objc private func conceal() { view.isHidden = true }
    @objc private func reveal() { view.isHidden = false }
    private func label(_ text: String, id: String) {
        let item = UILabel(); item.text = text; item.numberOfLines = 0; item.accessibilityIdentifier = id
        item.font = .preferredFont(forTextStyle: .body); item.adjustsFontForContentSizeCategory = true; stack.addArrangedSubview(item)
    }
    private func button(_ title: String, id: String, action: @escaping () -> Void) {
        let item = UIButton(type: .system); var config = UIButton.Configuration.tinted(); config.title = title
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12)
        item.configuration = config; item.accessibilityIdentifier = id
        item.addAction(UIAction { [weak self] _ in guard self?.busy == false else { return }; action() }, for: .touchUpInside)
        stack.addArrangedSubview(item)
    }
    private func run(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true
        operation = Task { @MainActor in
            defer { busy = false }
            do { try Task.checkCancellation(); try await action() }
            catch is CancellationError { }
            catch { unavailable() }
        }
    }
    private func refresh() {
        run { [self] in
            let records = try await store.list()
            stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
            label("Development candidate. Network verification and recovery funding are pending. Import does not mark an account ready.", id: "v5r2.pending")
            button("Import public recovery manifest", id: "v5r2.import") { [weak self] in self?.importManifest() }
            for record in records { label("\(record.name)\n\(record.address.toRaw())", id: "v5r2.account.\(record.id)") }
        }
    }
    private func importManifest() {
        let alert = UIAlertController(title: "Import initial identity", message: nil, preferredStyle: .alert)
        for (i, hint) in ["Account name", "Independently known wallet address", "Public recovery manifest"].enumerated() {
            alert.addTextField { field in field.placeholder = hint; field.accessibilityIdentifier = "v5r2.input.\(i)"; field.autocorrectionType = .no; field.autocapitalizationType = .none }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in alert.textFields?.forEach { $0.text = nil } })
        alert.addAction(UIAlertAction(title: "Import", style: .default) { [weak self] _ in
            let values = alert.textFields?.map { $0.text ?? "" } ?? []; alert.textFields?.forEach { $0.text = nil }
            guard let self, values.count == 3 else { return }
            run { [self] in
                _ = try await self.store.registerInitial(name: values[0], manifest: Data(values[2].utf8), independentlyKnownWallet: Address.parse(values[1]))
                // Reload after this operation has released the busy gate.
                DispatchQueue.main.async { [weak self] in self?.refresh() }
            }
        })
        present(alert, animated: true)
    }
    private func unavailable() {
        guard viewIfLoaded?.window != nil else { return }
        let alert = UIAlertController(title: "R2 operation unavailable", message: "Check the wallet identity, candidate network and device authentication.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
}
