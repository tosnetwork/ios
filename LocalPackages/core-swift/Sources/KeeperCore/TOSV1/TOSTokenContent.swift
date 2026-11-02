import Foundation
import CryptoKit
import TonSwift
import CoreComponents

/// Bounded TEP-64 codec for authenticated master content. A URI does not prove
/// its remote JSON or precision; unresolved offchain decimals remain nil.
public struct TOSTokenContent {
    public let name: String?
    public let symbol: String?
    public let decimals: Int?
    public let uri: String?

    private static func ordinary(_ cell: Cell) throws {
        guard !cell.isExotic, cell.level == 0 else { throw TOSPQError.invalidInput }
    }
    private static func text(_ slice: Slice, maximumBytes: Int) throws -> String {
        var bytes = Data(), current = slice
        for _ in 0..<256 {
            guard current.remainingBits % 8 == 0, (0...1).contains(current.remainingRefs),
                  current.remainingBits / 8 <= maximumBytes - bytes.count else { throw TOSPQError.invalidInput }
            bytes.append(try current.loadBytes(current.remainingBits / 8))
            if current.remainingRefs == 0 {
                guard let value = String(data: bytes, encoding: .utf8) else { throw TOSPQError.invalidInput }
                return value
            }
            let next = try current.loadRef(); try ordinary(next); current = try next.beginParse()
        }
        throw TOSPQError.invalidInput
    }
    private static func lookup(_ root: Cell?, field: String) throws -> Cell? {
        guard var cell = root else { return nil }
        let key = Array(SHA256.hash(data: Data(field.utf8)))
        func bit(_ offset: Int) -> Bool { (key[offset / 8] >> (7 - offset % 8)) & 1 != 0 }
        var offset = 0
        for _ in 0...256 {
            try ordinary(cell)
            let s = try cell.beginParse(), remaining = 256 - offset
            let same: Bool?, length: Int
            if try s.loadBoolean() == false {
                same = nil
                var count = 0
                while try s.loadBoolean() {
                    count += 1
                    guard count <= remaining else { throw TOSPQError.invalidInput }
                }
                length = count
            } else {
                let repeated = try s.loadBoolean()
                same = repeated ? try s.loadBoolean() : nil
                let width = remaining == 0 ? 0 : Int.bitWidth - remaining.leadingZeroBitCount
                length = width == 0 ? 0 : Int(try s.loadUint(bits: width))
                guard length <= remaining else { throw TOSPQError.invalidInput }
            }
            var matches = true
            for index in 0..<length {
                let actual: Bool
                if let same { actual = same } else { actual = try s.loadBoolean() }
                if actual != bit(offset + index) { matches = false }
            }
            if !matches { return nil }
            offset += length
            if offset == 256 {
                guard s.remainingBits == 0, s.remainingRefs == 1 else { throw TOSPQError.invalidInput }
                let value = try s.loadRef(); try ordinary(value); return value
            }
            guard s.remainingBits == 0, s.remainingRefs == 2 else { throw TOSPQError.invalidInput }
            let left = try s.loadRef(), right = try s.loadRef()
            cell = bit(offset) ? right : left; offset += 1
        }
        throw TOSPQError.invalidInput
    }
    public static func decode(_ content: Cell) throws -> Self {
        try ordinary(content)
        let s = try content.beginParse()
        switch try s.loadUint(bits: 8) {
        case 1:
            let uri = try text(s, maximumBytes: 2048)
            guard !uri.isEmpty else { throw TOSPQError.invalidInput }
            return Self(name: nil, symbol: nil, decimals: nil, uri: uri)
        case 0:
            let root: Cell?
            if try s.loadBoolean() { root = try s.loadRef() } else { root = nil }
            try s.endParse()
            func field(_ name: String, limit: Int) throws -> String? {
                guard let value = try lookup(root, field: name) else { return nil }
                let slice = try value.beginParse()
                guard try slice.loadUint(bits: 8) == 0 else { throw TOSPQError.invalidInput }
                let string = try text(slice, maximumBytes: limit)
                return string.isEmpty ? nil : string
            }
            let uri = try field("uri", limit: 2048), declared = try field("decimals", limit: 3)
            let decimals: Int?
            if let declared {
                guard declared.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(declared), value <= 255 else {
                    throw TOSPQError.invalidInput
                }
                decimals = value
            } else { decimals = uri == nil ? 9 : nil }
            return try Self(name: field("name", limit: 128), symbol: field("symbol", limit: 32), decimals: decimals, uri: uri)
        default: throw TOSPQError.invalidInput
        }
    }
}
