import Foundation
import BigInt
import TonSwift
import CoreComponents

/// Raw standard master storage; authenticate actual account/code before use.
struct TOSTokenMasterState {
    let totalSupply: BigUInt
    let content: Cell

    static func decode(_ data: Cell, expectedWalletCode: Cell) throws -> Self {
        guard !data.isExotic, data.level == 0 else { throw TOSPQError.invalidInput }
        let slice = try data.beginParse()
        let bytes = Int(try slice.loadUint(bits: 4))
        let supply = bytes == 0 ? BigUInt(0) : BigUInt(try slice.loadBytes(bytes))
        if try slice.preloadUint(bits: 2) == 0 { try slice.skip(2) }
        else { let _: Address = try slice.loadType() }
        let content = try slice.loadRef()
        guard !content.isExotic, content.level == 0,
              try slice.loadRef().hash() == expectedWalletCode.hash() else { throw TOSPQError.keyBinding }
        try slice.endParse()
        return Self(totalSupply: supply, content: content)
    }
}
