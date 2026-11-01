import UIKit
import UniformTypeIdentifiers
import KeeperCore

@MainActor
final class TOSQuantumBackupImportViewController: UIViewController, UIDocumentPickerDelegate {
    var didImport: (() -> Void)?
    private let controller: WalletAddController
    private let file = UIButton(type: .system), review = UIButton(type: .system), configure = UIButton(type: .system)
    private let password = UITextField(), status = UILabel()
    private var encrypted: Data?
    private var profile: TOSQuantumNetworkProfile?
    private var namespace: Data?
    private var operation: Task<Void, Never>?
    private var generation = UUID(), busy = false

    init(controller: WalletAddController) { self.controller = controller; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { return nil }
    deinit { operation?.cancel(); NotificationCenter.default.removeObserver(self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Encrypted TOS backup"; view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Cancel", style: .plain, target: self, action: #selector(cancel))
        let scroll = UIScrollView(), stack = UIStackView()
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false; stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical; stack.spacing = 18
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        func label(_ text: String) -> UILabel {
            let label = UILabel(); label.text = text; label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .body); label.adjustsFontForContentSizeCategory = true
            return label
        }
        stack.addArrangedSubview(label("Import an encrypted TOS backup to restore its original address. Payments remain locked during recovery. Keep your backup file and password."))
        button(file, title: "Choose backup file", id: "choose", action: #selector(chooseFile))
        button(configure, title: "Configure TOS network", id: "configure", action: #selector(configureNetwork))
        password.isSecureTextEntry = true; password.textContentType = .password
        password.returnKeyType = .done
        password.autocorrectionType = .no; password.autocapitalizationType = .none; password.spellCheckingType = .no
        password.borderStyle = .roundedRect; password.placeholder = "Backup file password"
        password.accessibilityIdentifier = "quantum.backup.password"
        password.font = .preferredFont(forTextStyle: .body); password.adjustsFontForContentSizeCategory = true
        password.addTarget(self, action: #selector(changed), for: .editingChanged)
        password.addTarget(self, action: #selector(endPasswordEditing), for: .editingDidEndOnExit)
        button(review, title: "Review backup", id: "review", action: #selector(reviewBackup))
        status.numberOfLines = 0; status.font = .preferredFont(forTextStyle: .body)
        status.adjustsFontForContentSizeCategory = true; status.accessibilityIdentifier = "quantum.backup.status"
        [file, configure, password, review, status].forEach(stack.addArrangedSubview)
        status.text = "Choose your encrypted backup file."
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true { clear() }
    }
    private func button(_ button: UIButton, title: String, id: String, action: Selector) {
        var style = UIButton.Configuration.tinted(); style.title = title
        style.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12)
        button.configuration = style; button.accessibilityIdentifier = "quantum.backup." + id
        button.addTarget(self, action: action, for: .touchUpInside)
    }
    private var validPassword: Bool {
        guard let value = password.text else { return false }
        return value.unicodeScalars.count >= 12 && value.utf8.count <= 1024 && !value.unicodeScalars.contains { $0.value == 0 }
    }
    @objc private func changed() { render() }
    @objc private func endPasswordEditing() { view.endEditing(true) }
    private func render() {
        file.isEnabled = !busy; configure.isEnabled = !busy; password.isEnabled = !busy
        review.isEnabled = !busy && encrypted != nil && validPassword
    }
    private func clear(keepFile: Bool = false) {
        operation?.cancel(); operation = nil; generation = UUID(); busy = false
        password.text = nil; profile = nil; namespace = nil
        if !keepFile { encrypted = nil }
        render()
    }
    @objc private func cancel() { clear(); navigationController?.popViewController(animated: true) }
    @objc private func backgrounded() {
        clear(); presentedViewController?.dismiss(animated: false)
        status.text = "Choose your backup again to continue."
    }
    @objc private func chooseFile() {
        clear()
        view.endEditing(true)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.allowsMultipleSelection = false; picker.delegate = self
        picker.modalPresentationStyle = .overFullScreen
        present(picker, animated: true)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        status.text = "No backup selected."; render()
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard urls.count == 1, let url = urls.first else { return }
        clear(); let token = generation; busy = true; status.text = "Reading backup…"; render()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let input: Data = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(with: Result { try TOSQuantumBackupDocument.read(url) })
                    }
                }
                guard !Task.isCancelled, token == generation else { return }
                encrypted = input; status.text = "Encrypted backup selected. Enter its password to review the original wallet."
                busy = false; operation = nil; render()
            } catch { failure(token: token, message: "Could not open this file. Choose a TOS encrypted backup file.") }
        }
    }
    @objc private func configureNetwork() {
        clear(keepFile: true); view.endEditing(true)
        TOSRPCNodeEditor.present(from: self) { [weak self] in
            self?.status.text = "Network settings saved. Enter the backup password and confirm the network to continue."
        }
    }
    @objc private func reviewBackup() {
        guard !busy, encrypted != nil, validPassword else { return }
        view.endEditing(true)
        let selected: TOSQuantumNetworkProfile
        do { selected = try TOSQuantumNetworkProfile.effective() }
        catch { status.text = "Configure a trusted TOS network first."; return }
        let token = generation
        let alert = UIAlertController(title: "Confirm Recovery Network",
            message: "Use the trusted network recorded with your backup. The file cannot change this selection.\n\nGlobal ID: \(selected.globalID)\nZerostate root hash: \(selected.rootHash)\nZerostate file hash: \(selected.fileHash)", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Use This Network", style: .default) { [weak self] _ in
            self?.inspect(profile: selected, token: token)
        })
        alert.addAction(UIAlertAction(title: "Change Trusted Network", style: .default) { [weak self] _ in self?.configureNetwork() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.password.text = nil; self?.render() })
        present(alert, animated: true)
    }
    private func inspect(profile selected: TOSQuantumNetworkProfile, token: UUID) {
        guard token == generation, let input = encrypted, let secret = password.text, validPassword, !busy else { return }
        busy = true; status.text = "Verifying the network and backup…"; render()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let approvedNamespace = try await controller.quantumRecoveryNamespace(profile: selected)
                let preview = try await controller.inspectQuantumBackup(encrypted: input, password: secret,
                    profile: selected, expectedNamespace: approvedNamespace)
                guard !Task.isCancelled, token == generation else { return }
                profile = selected; namespace = approvedNamespace; busy = false; operation = nil; render()
                let roles = [preview.containsPrimary ? "primary key" : nil, preview.containsRescue ? "rescue key" : nil].compactMap { $0 }.joined(separator: ", ")
                let alert = UIAlertController(title: "Review Recovery Wallet",
                    message: "Original address:\n\(preview.address)\n\nThis backup contains: \(roles).\n\nPayments remain locked during recovery. Keep your original backup.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Import Recovery Wallet", style: .default) { [weak self] _ in self?.importReviewed(token: token) })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                    self?.password.text = nil; self?.profile = nil; self?.namespace = nil; self?.render()
                })
                present(alert, animated: true)
            } catch { failure(token: token, message: "Could not verify this backup. Check its password, trusted network and TOS node, then try again.") }
        }
    }
    private func importReviewed(token: UUID) {
        guard token == generation, !busy, let input = encrypted, let secret = password.text, validPassword,
              let selected = profile, let approvedNamespace = namespace else { return }
        password.text = nil; busy = true; status.text = "Importing recovery wallet…"; render()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await controller.importQuantumBackup(metaData: WalletMetaData(label: "Recovered wallet",
                    tintColor: .defaultColor, icon: .icon(.wallet)), encrypted: input, password: secret,
                    profile: selected, expectedNamespace: approvedNamespace)
                guard !Task.isCancelled, token == generation else { return }
                operation = nil; clear(); didImport?()
            } catch { failure(token: token, message: "Import could not finish. Keep the same backup and retry. Payments remain locked. Ensure this device has a passcode and the TOS node is available.") }
        }
    }
    private func failure(token: UUID, message: String) {
        guard token == generation else { return }
        operation = nil; busy = false; password.text = nil; profile = nil; namespace = nil
        status.text = message; render()
    }
}
