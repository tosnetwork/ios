import Foundation
import BigInt
import CoreComponents
import TonAPI
import TonSwift

protocol TonBalanceService {
    func loadBalance(wallet: Wallet) async throws -> TonBalance
}

final class TonBalanceServiceImplementation: TonBalanceService {
    private let apiProvider: APIProvider
    private let quantumReader = TOSQuantumAccountReader()

    init(apiProvider: APIProvider) {
        self.apiProvider = apiProvider
    }

    func loadBalance(wallet: Wallet) async throws -> TonBalance {
        if wallet.kind == .quantum {
            return TonBalance(amount: try await quantumReader.read(wallet: wallet).balance)
        }
        let account = try await apiProvider.api(wallet.network).getAccountInfo(accountId: wallet.address.toRaw())
        guard account.balance >= 0 else { throw TOSPQError.invalidInput }
        return TonBalance(amount: BigUInt(account.balance))
    }
}
