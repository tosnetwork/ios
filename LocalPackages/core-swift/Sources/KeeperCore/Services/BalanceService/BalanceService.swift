import BigInt
import Foundation
import TonSwift

public protocol BalanceService {
    func loadWalletBalance(
        wallet: Wallet,
        currency: Currency,
        includingTransferFees: Bool
    ) async throws -> WalletBalance
    func getBalance(wallet: Wallet) throws -> WalletBalance
}

final class BalanceServiceImplementation: BalanceService {
    private let tonBalanceService: TonBalanceService
    private let jettonsBalanceService: JettonBalanceService
    private let tronBalanceService: TronBalanceService
    private let batteryService: BatteryService
    private let stackingService: StakingService
    private let tonProofTokenService: TonProofTokenService
    private let walletBalanceRepository: WalletBalanceRepository

    init(
        tonBalanceService: TonBalanceService,
        jettonsBalanceService: JettonBalanceService,
        tronBalanceService: TronBalanceService,
        batteryService: BatteryService,
        stackingService: StakingService,
        tonProofTokenService: TonProofTokenService,
        walletBalanceRepository: WalletBalanceRepository
    ) {
        self.tonBalanceService = tonBalanceService
        self.jettonsBalanceService = jettonsBalanceService
        self.tronBalanceService = tronBalanceService
        self.batteryService = batteryService
        self.stackingService = stackingService
        self.tonProofTokenService = tonProofTokenService
        self.walletBalanceRepository = walletBalanceRepository
    }

    func loadWalletBalance(
        wallet: Wallet,
        currency: Currency,
        includingTransferFees: Bool
    ) async throws -> WalletBalance {
        let tonBalance = try await tonBalanceService.loadBalance(wallet: wallet)

        let balance = Balance(
            tonBalance: tonBalance,
            jettonsBalance: []
        )

        let walletBalance = WalletBalance(
            date: Date(),
            balance: balance,
            stacking: [],
            batteryBalance: nil,
            tronBalance: nil
        )

        try? walletBalanceRepository.saveWalletBalance(
            walletBalance,
            for: wallet
        )

        return walletBalance
    }

    func getBalance(wallet: Wallet) throws -> WalletBalance {
        try walletBalanceRepository.getWalletBalance(wallet: wallet)
    }
}
