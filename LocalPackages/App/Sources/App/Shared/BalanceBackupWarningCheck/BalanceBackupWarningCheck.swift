import Foundation
import BigInt
import KeeperCore

struct BalanceBackupWarningCheck {
    enum State {
        case error
        case warning
        case none
    }

    func check(wallet: Wallet, tonAmount: BigUInt) -> State {
        guard wallet.isBackupAvailable else { return .none }
        guard !wallet.hasBackup else { return .none }
        switch tonAmount {
        case _ where tonAmount >= .tonAmountError:
            return .error
        case _ where tonAmount >= .tonAmountWarning:
            return .warning
        default:
            return .none
        }
    }
}

private extension BigUInt {
    static let tonAmountWarning: BigUInt = 2_000_000_000
    static let tonAmountError: BigUInt = 20_000_000_000
}
