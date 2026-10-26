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
        let quantum = UIAlertAction(title: "Trusted Quantum Network", style: .default) { [weak presenter] _ in
            guard let presenter else { return }
            presentQuantumNetwork(from: presenter, onSaved: onSaved)
        }
        quantum.accessibilityIdentifier = "settings.rpc.quantumNetwork"
        alert.addAction(quantum)
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

    private static func presentQuantumNetwork(from presenter: UIViewController, onSaved: @escaping () -> Void) {
        let profile = try? TOSQuantumNetworkProfile.selected()
        let alert = UIAlertController(title: "Trusted Quantum Network",
            message: "Use the network ID and genesis hashes from a trusted network configuration obtained separately from your RPC node. Existing wallets keep their original network.", preferredStyle: .alert)
        for (name, value) in [("Network ID", profile.map { String($0.globalID) }),
                              ("Genesis root hash", profile?.rootHash), ("Genesis file hash", profile?.fileHash)] {
            alert.addTextField { field in
                field.placeholder = name; field.text = value
                field.accessibilityLabel = name
                field.autocapitalizationType = .none; field.autocorrectionType = .no
            }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak presenter, weak alert] _ in
            do {
                guard let fields = alert?.textFields,
                      let id = Int32((fields[0].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw TOSQuantumNetworkProfile.Error.invalidProfile
                }
                try TOSQuantumNetworkProfile(globalID: id, rootHash: fields[1].text ?? "", fileHash: fields[2].text ?? "").select()
                onSaved()
            } catch {
                let errorAlert = UIAlertController(title: "Invalid Network Configuration", message: error.localizedDescription, preferredStyle: .alert)
                errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                presenter?.present(errorAlert, animated: true)
            }
        })
        presenter.present(alert, animated: true)
    }
}
