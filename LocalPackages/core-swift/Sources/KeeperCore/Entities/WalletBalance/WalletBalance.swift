import BigInt
import Foundation

public struct WalletBalance: Codable, Equatable {
    public let date: Date
    public let balance: Balance
    public let stacking: [AccountStackingInfo]
    public let batteryBalance: BatteryBalance?
    public let tronBalance: TronBalance?
    public let tokenNotice: String?

    public init(date: Date, balance: Balance, stacking: [AccountStackingInfo], batteryBalance: BatteryBalance?,
                tronBalance: TronBalance?, tokenNotice: String? = nil) {
        self.date = date; self.balance = balance; self.stacking = stacking
        self.batteryBalance = batteryBalance; self.tronBalance = tronBalance; self.tokenNotice = tokenNotice
    }
}
