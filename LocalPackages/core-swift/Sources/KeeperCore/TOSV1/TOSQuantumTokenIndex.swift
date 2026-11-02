import Foundation
import CoreFoundation
import CoreComponents

/// Untrusted discovery hints. Neither entries nor node flags prove balances.
struct TOSQuantumTokenIndex {
    struct Position: Equatable { let wallet: String; let master: String }
    static let maximumRows = 10_000
    let positions: [Position]
    let nodeReportsComplete: Bool
    let reachedRowLimit: Bool

    static func decode(_ value: [String: Any]) throws -> Self {
        guard value["@type"] as? String == "wallet.accountTokens",
              let rows = value["tokens"] as? [[String: Any]], rows.count <= maximumRows else {
            throw TOSPQError.invalidInput
        }
        var wallets = Set<String>(), masters = Set<String>()
        func address(_ value: Any?) throws -> String {
            guard let text = value as? String, text.utf8.count == 66,
                  text.range(of: "^0:[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
                throw TOSPQError.invalidInput
            }
            return text.lowercased()
        }
        let positions = try rows.map { row in
            let wallet = try address(row["token_wallet"]), master = try address(row["token_master"])
            guard wallets.insert(wallet).inserted, masters.insert(master).inserted else { throw TOSPQError.invalidInput }
            return Position(wallet: wallet, master: master)
        }
        func boolean(_ value: Any?) -> Bool? {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        let state = value["index_state"] as? [String: Any]
        return Self(positions: positions,
                    nodeReportsComplete: boolean(state?["complete"]) == true && boolean(state?["ownership_complete"]) != false,
                    reachedRowLimit: rows.count == maximumRows)
    }
}
