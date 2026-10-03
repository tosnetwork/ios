import Foundation

struct TOSWalletTransactionCursor: Equatable, Sendable {
    let lt: Int64
    let txHash: String

    static func decode(_ response: [String: Any]) throws -> TOSWalletTransactionCursor {
        guard let transaction = response["last_transaction_id"] as? [String: Any],
              let logicalTime = transaction["lt"] as? String,
              !logicalTime.isEmpty,
              logicalTime.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let lt = Int64(logicalTime),
              let encodedHash = transaction["hash"] as? String,
              let hash = Data(base64Encoded: encodedHash), hash.count == 32,
              hash.base64EncodedString() == encodedHash
        else { throw TOSRPCClient.Error.invalidResponse }
        return TOSWalletTransactionCursor(
            lt: lt,
            txHash: hash.map { String(format: "%02x", $0) }.joined()
        )
    }
}

extension TOSRPCClient {
    func walletBackgroundUpdateCursor(wallet: Wallet) async throws -> TOSWalletTransactionCursor {
        let response = try await callForWallet(
            method: "getWalletInformation",
            params: ["address": try wallet.address.toRaw()],
            wallet: wallet
        )
        return try TOSWalletTransactionCursor.decode(response)
    }
}

extension API {
    func walletBackgroundUpdateCursor(wallet: Wallet) async throws -> TOSWalletTransactionCursor {
        let client = await boundTOSRPCClient()
        return try await client.walletBackgroundUpdateCursor(wallet: wallet)
    }
}
