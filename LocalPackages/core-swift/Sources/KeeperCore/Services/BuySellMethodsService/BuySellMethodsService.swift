import Foundation
import TonAPI

public protocol BuySellMethodsService {
    func loadFiatMethods(countryCode: String?) async throws -> FiatMethods
}

final class BuySellMethodsServiceImplementation: BuySellMethodsService {
    private let api: TosWalletAPI
    private let buySellMethodsRepository: BuySellMethodsRepository

    init(
        api: TosWalletAPI,
        buySellMethodsRepository: BuySellMethodsRepository
    ) {
        self.api = api
        self.buySellMethodsRepository = buySellMethodsRepository
    }

    func loadFiatMethods(countryCode: String?) async throws -> FiatMethods {
        do {
            return try await api.loadFiatMethods(countryCode: countryCode)
        } catch {
            throw error
        }
    }
}
