import Foundation
import BigInt
import TonSwift
import CoreComponents

/// Standard Token storage codec. Raw decoding alone is not authenticated balance evidence.
public struct TOSTokenWalletState {
    public let balance: BigUInt
    public let owner: Address
    public let master: Address

    private static func ordinary(_ cell: Cell) throws {
        guard !cell.isExotic, cell.level == 0 else { throw TOSPQError.invalidInput }
    }
    private static func basechain(_ address: Address) throws {
        guard address.workchain == 0, address.hash.count == 32 else { throw TOSPQError.invalidInput }
    }
    public static func address(owner: Address, master: Address, walletCode: Cell) throws -> Address {
        try basechain(owner); try basechain(master); try ordinary(walletCode)
        let data = try Builder().store(uint: 0, bits: 4).store(owner).store(master).store(ref: walletCode).endCell()
        let initial = try Builder().store(uint: 6, bits: 5).store(ref: walletCode).store(ref: data).endCell()
        return Address(workchain: 0, hash: initial.hash())
    }

    /// Caller must authenticate the account and match its actual code to a locally
    /// supported implementation before using this storage as a Token position.
    public static func decode(_ data: Cell, wallet: Address, owner: Address, master: Address,
                              walletCode: Cell) throws -> Self {
        try ordinary(data); try ordinary(walletCode)
        try basechain(wallet); try basechain(owner); try basechain(master)
        guard wallet == (try address(owner: owner, master: master, walletCode: walletCode)) else {
            throw TOSPQError.keyBinding
        }
        let slice = try data.beginParse()
        let bytes = Int(try slice.loadUint(bits: 4))
        let balance = bytes == 0 ? BigUInt(0) : BigUInt(try slice.loadBytes(bytes))
        let storedOwner: Address = try slice.loadType()
        let storedMaster: Address = try slice.loadType()
        guard storedOwner == owner, storedMaster == master,
              try slice.loadRef().hash() == walletCode.hash() else { throw TOSPQError.keyBinding }
        try slice.endParse()
        return Self(balance: balance, owner: owner, master: master)
    }
}
