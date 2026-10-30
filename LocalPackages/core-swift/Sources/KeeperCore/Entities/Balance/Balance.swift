import BigInt
import Foundation
import TonSwift

public struct Balance: Codable, Equatable {
    public let tonBalance: TonBalance
    public let jettonsBalance: [JettonBalance]

    public init(
        tonBalance: TonBalance,
        jettonsBalance: [JettonBalance]
    ) {
        self.tonBalance = tonBalance
        self.jettonsBalance = jettonsBalance
    }
}

public extension Balance {
    var isEmptyJettonsBalance: Bool {
        jettonsBalance.filter { !$0.quantity.isZero && $0.item.jettonInfo.verification != .blacklist }.isEmpty
    }

    var isEmpty: Bool {
        tonBalance.amount == 0 && isEmptyJettonsBalance
    }
}

public struct TonBalance: Codable, Equatable {
    public let amount: BigUInt

    public init(amount: BigUInt) {
        self.amount = amount
    }

    private enum CodingKeys: CodingKey { case amount }
    public init(from decoder: Decoder) throws {
        amount = try decoder.container(keyedBy: CodingKeys.self).decode(NativeBalanceAmount.self, forKey: .amount).value
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(NativeBalanceAmount(value: amount), forKey: .amount)
    }
}

/// Decimal strings preserve the full unsigned coin range; old numeric caches
/// remain readable without passing through floating-point JSON values.
internal struct NativeBalanceAmount: Codable {
    let value: BigUInt
    init(value: BigUInt) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            guard !string.isEmpty, string.utf8.count <= 37,
                  string == "0" || string.first != "0",
                  string.utf8.allSatisfy({ (48...57).contains($0) }),
                  let amount = BigUInt(string), amount < BigUInt(1) << 120 else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid unsigned native balance")
            }
            value = amount
        } else {
            value = BigUInt(try container.decode(UInt64.self))
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(value))
    }
}

public struct JettonBalance: Codable, Equatable {
    public let item: JettonItem
    public let quantity: BigUInt
    public let rates: [Currency: Rates.Rate]

    public var scaledBalance: BigUInt? {
        guard let scaleValue = item.jettonInfo.scaleValue else {
            return nil
        }

        return BigUInt.mulFixed(quantity, scaleValue, fractionDigits: item.jettonInfo.fractionDigits)
    }

    public init(
        item: JettonItem,
        quantity: BigUInt,
        rates: [Currency: Rates.Rate]
    ) {
        self.item = item
        self.quantity = quantity
        self.rates = rates
    }
}

public struct JettonItem: Codable, Equatable, Hashable {
    public let jettonInfo: JettonInfo
    public let walletAddress: Address?

    public init(jettonInfo: JettonInfo, walletAddress: Address?) {
        self.jettonInfo = jettonInfo
        self.walletAddress = walletAddress
    }
}

public struct TonInfo {
    public static let name = "TOS"
    public static let symbol = "TOS"
    public static let fractionDigits = 9
    private init() {}
}

public struct JettonInfo: Codable, Equatable, Hashable {
    public enum Verification: Codable {
        case none
        case whitelist
        case blacklist
        case graylist
    }

    public let isTransferable: Bool
    public let hasCustomPayload: Bool
    public let address: Address
    public let fractionDigits: Int
    public let name: String
    public let symbol: String?
    public let verification: Verification
    public let imageURL: URL?
    public let numerator: BigUInt?
    public let denomenator: BigUInt?

    public init(
        isTransferable: Bool,
        hasCustomPayload: Bool,
        address: Address,
        fractionDigits: Int,
        name: String,
        symbol: String?,
        verification: Verification,
        imageURL: URL?,
        numerator: BigUInt? = nil,
        denomenator: BigUInt? = nil
    ) {
        self.isTransferable = isTransferable
        self.hasCustomPayload = hasCustomPayload
        self.address = address
        self.fractionDigits = fractionDigits
        self.name = name
        self.symbol = symbol
        self.verification = verification
        self.imageURL = imageURL
        self.numerator = numerator
        self.denomenator = denomenator
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.address == rhs.address
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(address)
    }
}

public extension JettonInfo {
    var isTonUSDT: Bool {
        address == JettonMasterAddress.tonUSDT
    }

    var isUSDe: Bool {
        address == JettonMasterAddress.USDe
    }

    var isTsUSDe: Bool {
        address == JettonMasterAddress.tsUSDe
    }

    var scaleValue: BigUInt? {
        guard let numerator, let denomenator else { return nil }
        return BigUInt
            .divide(
                numerator, scaleN: fractionDigits,
                by: denomenator, scaleD: fractionDigits,
                resultScale: fractionDigits
            )
    }

    var isUnverified: Bool {
        switch verification {
        case .whitelist, .graylist:
            return false
        case .blacklist, .none:
            return true
        }
    }
}

public enum JettonMasterAddress {
    public static let tonUSDT = try! Address.parse("0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe")
    public static let tonstakers = try! Address.parse("0:bdf3fa8098d129b54b4f73b5bac5d1e1fd91eb054169c3916dfc8ccd536d1000")
    public static let NOT = try! Address.parse("0:2f956143c461769579baef2e32cc2d7bc18283f40d20bb03e432cd603ac33ffc")
    public static let HMSTR = try! Address.parse("0:09f2e59dec406ab26a5259a45d7ff23ef11f3e5c7c21de0b0d2a1cbe52b76b3d")
    public static let USDe = try! Address.parse("0:086fa2a675f74347b08dd4606a549b8fdb98829cb282bc1949d3b12fbaed9dcc")
    public static let tsUSDe = try! Address.parse("0:d0e545323c7acb7102653c073377f7e3c67f122eb94d430a250739f109d4a57d")
}

public extension BigUInt {
    static func divide(
        _ N: BigUInt, scaleN a: Int,
        by D: BigUInt, scaleD b: Int,
        resultScale r: Int
    ) -> BigUInt {
        precondition(D != 0)

        let ten = BigUInt(10)
        let factor = ten.power(b + r) // 10^(b + r)
        let scaledNumerator = N * factor
        let scaledDenominator = D * ten.power(a)

        return scaledNumerator / scaledDenominator
    }

    static func divideRoundHalfUp(
        _ N: BigUInt, scaleN a: Int,
        by D: BigUInt, scaleD b: Int,
        resultScale r: Int
    ) -> BigUInt {
        precondition(D != 0)

        let ten = BigUInt(10)
        let factor = ten.power(b + r) // 10^(b + r)
        let scaledNumerator = N * factor
        let scaledDenominator = D * ten.power(a)

        let (q, rem) = scaledNumerator.quotientAndRemainder(dividingBy: scaledDenominator)

        if rem.isZero { return q }
        if rem << 1 >= scaledDenominator {
            return q + 1
        } else {
            return q
        }
    }

    static func mulFixed(
        _ a: BigUInt,
        _ b: BigUInt,
        fractionDigits: Int
    ) -> BigUInt {
        let factor = BigUInt(10).power(fractionDigits)
        return (a * b) / factor
    }
}
