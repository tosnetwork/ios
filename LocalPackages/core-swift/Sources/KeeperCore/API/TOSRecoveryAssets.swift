import Foundation
import CoreFoundation
import BigInt

struct TOSRecoveryAccount {
    let amount: BigUInt
    let deployed: Bool

    static func parse(_ response: [String: Any]) throws -> Self {
        guard let text = response["balance"] as? String, !text.isEmpty, text.utf8.count <= 37,
              text.utf8.allSatisfy({ (48...57).contains($0) }),
              let amount = BigUInt(text), amount.bitWidth <= 120,
              let status = response["state"] as? String,
              ["active", "uninit", "uninitialized", "nonexist", "frozen"].contains(status) else {
            throw TOSRPCClient.Error.invalidResponse
        }
        return Self(amount: amount, deployed: status == "active" || status == "frozen")
    }
}

/// Index hints for recovery selection, never balance proof or signing authority.
struct TOSRecoveryAssets {
    let hasAssets: Bool
    let complete: Bool

    static func parse(tokens: [String: Any], nfts: [String: Any]) throws -> Self {
        guard tokens["@type"] as? String == "wallet.accountTokens",
              nfts["@type"] as? String == "wallet.accountNfts",
              let tokenRows = tokens["tokens"] as? [[String: Any]], tokenRows.count <= 1,
              let nftRows = nfts["nfts"] as? [[String: Any]], nftRows.count <= 1,
              tokenRows.allSatisfy({ ($0["token_wallet"] as? String)?.isEmpty == false }),
              nftRows.allSatisfy({ ($0["nft_item"] as? String)?.isEmpty == false }) else {
            throw TOSRPCClient.Error.invalidResponse
        }
        func complete(_ value: [String: Any]) -> Bool {
            guard let state = value["index_state"] as? [String: Any],
                  let flag = state["complete"] as? NSNumber,
                  CFGetTypeID(flag) == CFBooleanGetTypeID() else { return false }
            return flag.boolValue
        }
        return Self(hasAssets: !tokenRows.isEmpty || !nftRows.isEmpty,
                    complete: complete(tokens) && complete(nfts))
    }
}

extension TOSRPCClient {
    func recoveryAssets(address: String) async throws -> TOSRecoveryAssets {
        let params: [String: Any] = ["address": address, "limit": 1]
        let tokens = try await call(method: "getAccountTokens", params: params)
        let nfts = try await call(method: "getAccountNfts", params: params)
        return try TOSRecoveryAssets.parse(tokens: tokens, nfts: nfts)
    }
}
