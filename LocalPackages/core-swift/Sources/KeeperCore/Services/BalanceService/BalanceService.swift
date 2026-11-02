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
        let balance: Balance
        var tokenNotice: String?
        if wallet.kind == .quantum {
            let observed = try await TOSQuantumTokenAssetsReader().read(wallet: wallet)
            balance = Balance(tonBalance: TonBalance(amount: observed.native.balance), jettonsBalance: observed.tokens)
            if observed.discoveryFailed {
                tokenNotice = "Token balances could not be loaded. Pull down to retry."
            } else if observed.unreadPositions > 0 || observed.reachedRowLimit || !observed.nodeReportsComplete {
                tokenNotice = "The Token list may be incomplete. Pull down to retry or select another node."
            } else if observed.unresolvedPrecision > 0 {
                tokenNotice = "Some Tokens have unavailable precision and cannot yet display a balance."
            }
        } else {
            balance = Balance(tonBalance: try await tonBalanceService.loadBalance(wallet: wallet), jettonsBalance: [])
        }

        let walletBalance = WalletBalance(
            date: Date(),
            balance: balance,
            stacking: [],
            batteryBalance: nil,
            tronBalance: nil,
            tokenNotice: tokenNotice
        )

        if wallet.kind != .quantum {
            try? walletBalanceRepository.saveWalletBalance(walletBalance, for: wallet)
        }

        return walletBalance
    }

    func getBalance(wallet: Wallet) throws -> WalletBalance {
        guard wallet.kind != .quantum else { throw Wallet.Error.invalidWalletKind }
        return try walletBalanceRepository.getWalletBalance(wallet: wallet)
    }
}
