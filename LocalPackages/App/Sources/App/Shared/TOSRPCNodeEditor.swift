import KeeperCore
import UIKit

/// Available before wallet creation as well as from wallet settings.
enum TOSRPCNodeEditor {
    static func present(from presenter: UIViewController, onSaved: @escaping () -> Void) {
        let alert = UIAlertController(
            title: "RPC Node",
            message: "Enter a TOS node URL or IP address with an optional port. The wallet verifies its network before sending.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.accessibilityIdentifier = "settings.rpc.endpoint"
            field.accessibilityLabel = "RPC node endpoint"
            field.placeholder = "192.168.1.20:18545"
            field.text = TOSRPCSettings.customEndpoint
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let restore = UIAlertAction(title: "Restore Default", style: .destructive) { _ in
            TOSRPCSettings.reset()
            onSaved()
        }
        restore.accessibilityIdentifier = "settings.rpc.restore"
        alert.addAction(restore)
        let save = UIAlertAction(title: "Save", style: .default) { [weak presenter, weak alert] _ in
            do {
                try TOSRPCSettings.setCustomEndpoint(alert?.textFields?.first?.text ?? "")
                onSaved()
            } catch {
                let errorAlert = UIAlertController(title: "Invalid RPC Node", message: error.localizedDescription, preferredStyle: .alert)
                errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                presenter?.present(errorAlert, animated: true)
            }
        }
        save.accessibilityIdentifier = "settings.rpc.save"
        alert.addAction(save)
        presenter.present(alert, animated: true)
    }
}
