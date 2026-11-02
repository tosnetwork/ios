import Foundation
import BigInt

/// Exact TEP-74 VarUInteger 16 quantities; metadata precision is bounded to uint8.
public enum TOSTokenAmount {
    public enum Error: Swift.Error { case invalidAmount }

    private static func scale(_ decimals: Int) throws -> BigUInt {
        guard (0...255).contains(decimals) else { throw Error.invalidAmount }
        return BigUInt(10).power(decimals)
    }

    public static func parse(_ text: String, decimals: Int) throws -> BigUInt {
        let multiplier = try scale(decimals)
        guard (1...(38 + decimals)).contains(text.utf8.count) else { throw Error.invalidAmount }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let whole = parts.first, !whole.isEmpty,
              whole.utf8.allSatisfy({ (48...57).contains($0) }),
              whole == "0" || whole.first != "0", let integer = BigUInt(String(whole)) else {
            throw Error.invalidAmount
        }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard (parts.count == 1 || !fraction.isEmpty), fraction.utf8.count <= decimals,
              fraction.utf8.allSatisfy({ (48...57).contains($0) }) else { throw Error.invalidAmount }
        let padded = fraction + String(repeating: "0", count: decimals - fraction.utf8.count)
        guard let fractional = BigUInt(padded.isEmpty ? "0" : padded) else { throw Error.invalidAmount }
        let units = integer * multiplier + fractional
        guard units > 0, units.bitWidth <= 120 else { throw Error.invalidAmount }
        return units
    }

    public static func format(_ units: BigUInt, decimals: Int) throws -> String {
        let divisor = try scale(decimals)
        guard units.bitWidth <= 120 else { throw Error.invalidAmount }
        guard decimals > 0 else { return String(units) }
        let parts = units.quotientAndRemainder(dividingBy: divisor)
        let remainder = String(parts.remainder)
        var fraction = String(repeating: "0", count: decimals - remainder.count) + remainder
        while fraction.last == "0" { fraction.removeLast() }
        return String(parts.quotient) + (fraction.isEmpty ? "" : "." + fraction)
    }
}
