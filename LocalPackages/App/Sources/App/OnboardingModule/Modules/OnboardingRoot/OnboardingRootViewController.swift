import TKUIKit
import UIKit
import LocalAuthentication

final class OnboardingRootViewController: GenericViewViewController<OnboardingRootView> {
    private let viewModel: OnboardingRootViewModel

    init(viewModel: OnboardingRootViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        customView.termsTextView.delegate = self
        customView.configureNodeButton.addTarget(self, action: #selector(configureNode), for: .touchUpInside)
        customView.v5r2Button.addTarget(self, action: #selector(openV5R2), for: .touchUpInside)
        setupBindings()
        viewModel.viewDidLoad()
    }
}

private extension OnboardingRootViewController {
    @objc func openV5R2() {
        do {
            let controller = try TOSV5R2WalletsViewController(authenticate: {
                let context = LAContext()
                defer { context.invalidate() }
                guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
                return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Access V5R2 wallet material")) == true
            })
            let navigation = UINavigationController(rootViewController: controller)
            controller.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) })
            present(navigation, animated: true)
        } catch {
            let alert = UIAlertController(title: "R2 operation unavailable", message: "The wallet candidate could not be loaded.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    @objc func configureNode() {
        TOSRPCNodeEditor.present(from: self, onSaved: {})
    }

    func setupBindings() {
        viewModel.didUpdateModel = { [customView] model in
            customView.configure(model: model)
        }
    }
}

extension OnboardingRootViewController: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        shouldInteractWith url: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        UIApplication.shared.open(url)
        return false
    }
}
