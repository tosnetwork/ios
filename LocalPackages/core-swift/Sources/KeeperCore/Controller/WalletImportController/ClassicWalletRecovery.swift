import Foundation
import CoreComponents

/// Retain potential assets without presenting contract-version choices.
public enum ClassicWalletRecovery {
    public static func select(_ models: [ActiveWalletModel], fallback: WalletContractVersion) throws -> [ActiveWalletModel] {
        guard !models.isEmpty, models.count <= 64,
              Set(models.map { $0.address.toRaw() }).count == models.count else { throw TOSPQError.invalidInput }
        let retained = models.filter {
            !$0.balance.isEmpty || !$0.nfts.isEmpty || $0.hasIndexedAssets ||
            !$0.assetDiscoveryComplete || !$0.accountStateKnown
        }
        if !retained.isEmpty { return retained.sorted { $0.revision > $1.revision } }
        guard let model = models.first(where: { $0.revision == fallback }) else { throw TOSPQError.invalidInput }
        return [model]
    }

    public static func labels(base: String, count: Int) throws -> [String] {
        guard (1...64).contains(count) else { throw TOSPQError.invalidInput }
        return (0..<count).map { count == 1 ? base : "\(base) \($0 + 1)" }
    }
}
