import Foundation
import TonSwift
import CoreComponents

/// Exact ConfigParam48 v1 semantics. Caller binds authenticated checkpoint and local time.
public enum TOSQuantumRetirementPolicy {
    private static let spec: Data = {
        let text = "5e4380aedc95f8cb72de55f7506de0269b47c03ad1d1ed0e5184c332544262c0"
        return Data(stride(from: 0, to: text.count, by: 2).map { i in
            let start = text.index(text.startIndex, offsetBy: i)
            return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
        })
    }()
    public static func requirePrimary(_ cell: Cell, network: Data, now: UInt32) throws {
        guard network.count == 32, !cell.isExotic, cell.level == 0 else { throw TOSPQError.invalidInput }
        let s = try cell.beginParse()
        guard try s.loadUint(bits: 8) == 0xa1, try s.loadBytes(32) == network else { throw TOSPQError.keyBinding }
        try s.skip(64)
        let retired = UInt16(try s.loadUint(bits: 16))
        guard retired & ~UInt16(2) == 0 else { throw TOSPQError.invalidInput }
        let schedule = try s.loadMaybeRef()
        guard try s.loadBytes(32) == spec else { throw TOSPQError.keyBinding }
        try s.endParse()
        var deadline: UInt32 = 0
        if let schedule {
            guard !schedule.isExotic, schedule.level == 0 else { throw TOSPQError.invalidInput }
            let d = try schedule.beginParse()
            var same = false, repeated = false
            let length: Int
            if try d.loadBoolean() == false {
                var count = 0
                while try d.loadBoolean() { count += 1; guard count <= 8 else { throw TOSPQError.invalidInput } }
                length = count
            } else if try d.loadBoolean() == false { length = Int(try d.loadUint(bits: 4)) }
            else { same = true; repeated = try d.loadBoolean(); length = Int(try d.loadUint(bits: 4)) }
            guard length == 8 else { throw TOSPQError.invalidInput }
            let key = same ? (repeated ? 255 : 0) : Int(try d.loadUint(bits: 8))
            guard key == 1, d.remainingBits == 32, d.remainingRefs == 0 else { throw TOSPQError.invalidInput }
            deadline = UInt32(try d.loadUint(bits: 32))
            guard deadline > 0 else { throw TOSPQError.invalidInput }
        }
        guard retired & 2 == 0, deadline == 0 || now < deadline else { throw TOSPQError.keyBinding }
    }
}
