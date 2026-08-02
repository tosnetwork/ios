import BigInt
import KeeperCore
import TKCore
import TKLocalize
import TKUIKit
import UIKit

struct WalletBalanceHeaderMapper {
    private let amountFormatter: AmountFormatter
    private let dateFormatter: DateFormatter

    init(
        amountFormatter: AmountFormatter,
        dateFormatter: DateFormatter
    ) {
        self.amountFormatter = amountFormatter
        self.dateFormatter = dateFormatter
    }

    func makeUpdatedDate(_ date: Date) -> String {
        dateFormatter.dateFormat = "d MMM HH:mm"
        return dateFormatter.string(from: date)
    }

    func mapTotalBalance(totalBalance: TotalBalance?) -> String {
        if let item = totalBalance?.balance.tonItems.first {
            return amountFormatter.format(
                amount: BigUInt(item.amount),
                fractionDigits: item.fractionalDigits,
                accessory: .symbol("TOS"),
                style: .compact
            )
        } else {
            return "-"
        }
    }
}
