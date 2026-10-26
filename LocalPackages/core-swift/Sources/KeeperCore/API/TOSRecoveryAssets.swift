import Foundation
import CoreFoundation

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
