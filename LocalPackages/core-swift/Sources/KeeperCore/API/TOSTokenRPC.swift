import Foundation
import TonSwift

// The node wire contract is separate from local asset type names.
enum TOSTokenRPC {
    static let accountTokensMethod = "getAccountTokens"

    static func positions(_ response: [String: Any]) throws -> [(wallet: String, master: String)] {
        guard let entries = response["tokens"] as? [[String: Any]] else {
            throw TOSRPCClient.Error.invalidResponse
        }
        return try entries.map { entry in
            guard let wallet = entry["token_wallet"] as? String, !wallet.isEmpty,
                  let master = entry["token_master"] as? String, !master.isEmpty
            else { throw TOSRPCClient.Error.invalidResponse }
            return (wallet: wallet, master: master)
        }
    }

    static func metadataURI(_ data: [String: Any]) throws -> String? {
        try requireMaster(data)
        return data["token_metadata_uri"] as? String
    }

    static func requireMaster(_ data: [String: Any]) throws {
        guard data["@type"] as? String == "ext.tokens.tokenMasterData" else {
            throw TOSRPCClient.Error.invalidResponse
        }
    }

    static func masterInfo(_ data: [String: Any], address: Address, offchain: [String: Any]?) throws -> JettonInfo {
        try requireMaster(data)
        let name = (data["token_name"] as? String)?.tosNilIfEmpty
            ?? (offchain?["name"] as? String)?.tosNilIfEmpty
            ?? "Jetton \(address.toRaw().suffix(6))"
        let symbol = (data["token_symbol"] as? String)?.tosNilIfEmpty
            ?? (offchain?["symbol"] as? String)?.tosNilIfEmpty
        let decimals = Int((data["token_decimals"] as? String)?.tosNilIfEmpty
            ?? (offchain?["decimals"] as? String)?.tosNilIfEmpty ?? "") ?? 9
        let image = (data["token_image"] as? String)?.tosNilIfEmpty
            ?? (offchain?["image"] as? String)?.tosNilIfEmpty
        return JettonInfo(
            isTransferable: true,
            hasCustomPayload: false,
            address: address,
            fractionDigits: decimals,
            name: name,
            symbol: symbol,
            verification: .none,
            imageURL: image.flatMap(URL.init(string:))
        )
    }
}

private extension String {
    var tosNilIfEmpty: String? { isEmpty ? nil : self }
}
