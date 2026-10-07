import XCTest
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSV5R2InstalledStateTests: XCTestCase {
    private func byte(_ n: UInt8) throws -> Cell { try Builder().store(uint: n, bits: 8).endCell() }
    private func birth() throws -> TOSV5R2Genesis {
        let codes = try TOSV5R2Codes(wallet: byte(1), module: byte(2), vault: byte(3))
        var key = Data(count: 60); key.replaceSubrange(0..<12, with: [0,0,0,1,0,0,0,8,0,0,0,3])
        return try TOSV5R2Genesis(codes: codes,
            pins: TOSV5R2CodePins(wallet: codes.wallet.hash(), module: codes.module.hash(), vault: codes.vault.hash()),
            globalId: 1, network: Data(repeating: 0x42, count: 32), walletId: 17, primaryKey: Data(count: 1312),
            rescueKey: Data(count: 32), policy: .ready, feeTreeId: Data(count: 32), feePublicKey: key, epoch0: 100)
    }
    private func wallet(_ birth: TOSV5R2Genesis, classic: Bool = false, key: Data = Data(count: 32), extensions: Bool = false,
                        id: UInt32 = 17, version: UInt8 = 4, mode: UInt8 = 2,
                        module: Cell? = nil, metadata: Cell? = nil, epoch: UInt64 = 1, nonce: UInt64 = 0) throws -> Cell {
        let auth = try Builder().store(uint: version, bits: 8).store(uint: mode, bits: 2).store(uint: 65535, bits: 16)
            .store(uint: epoch, bits: 64).store(uint: nonce, bits: 64).store(uint: nonce, bits: 64)
            .store(ref: module ?? birth.moduleInit).store(ref: metadata ?? birth.metadata).endCell()
        return try Builder().store(bit: classic).store(uint: UInt32.max, bits: 32).store(uint: id, bits: 32)
            .store(data: key).store(bit: extensions).store(ref: auth).endCell()
    }
    func testWalletIdentityAndUnsignedTerminalCounters() throws {
        let b = try birth()
        XCTAssertEqual(try TOSV5R2WalletData.parse(b.walletData, birth: b).epoch, 1)
        let saturated = try TOSV5R2WalletData.parse(wallet(b, epoch: .max, nonce: .max), birth: b)
        XCTAssertEqual(saturated.seqno, .max); XCTAssertEqual(saturated.epoch, .max)
        XCTAssertEqual(saturated.primaryNonce, .max); XCTAssertEqual(saturated.rescueNonce, .max)
        for cell in try [wallet(b, classic: true), wallet(b, key: Data(repeating: 1, count: 32)), wallet(b, extensions: true),
                         wallet(b, id: 18), wallet(b, version: 3), wallet(b, mode: 0), wallet(b, mode: 1), wallet(b, mode: 3),
                         wallet(b, module: byte(9)), wallet(b, metadata: byte(9))] {
            XCTAssertThrowsError(try TOSV5R2WalletData.parse(cell, birth: b), "Invalid wallet accepted")
        }
    }
    private func account(extra: UInt8 = 0, code: Cell, data: Cell, address: Address, split: Bool = false, trailing: Bool = false) throws -> Cell {
        let b = try Builder().store(bit: true).store(address).store(uint: 0, bits: 3).store(uint: 0, bits: 3).store(uint: extra, bits: 3)
        if extra == 1 { try b.store(data: Data(repeating: 4, count: 32)) }
        try b.store(uint: 100, bits: 32).store(bit: false).store(uint: 0, bits: 64)
            .store(uint: 0, bits: 4).store(bit: false).store(bit: true).store(bit: split)
        if split { try b.store(uint: 1, bits: 5) }
        try b.store(bit: false).store(bit: true).store(ref: code).store(bit: true).store(ref: data).store(bit: false)
        if trailing { try b.store(bit: false) }
        return try b.endCell()
    }
    func testTosStorageExtraAndAccountIdentity() throws {
        let code = try byte(1), data = try byte(2), address = Address(workchain: 0, hash: Data(repeating: 3, count: 32))
        for extra in [UInt8(0), 1] {
            let boc = try account(extra: extra, code: code, data: data, address: address).toBoc()
            XCTAssertEqual(try TOSV5R2AccountState.data(boc, expectedAddress: address, expectedCode: code).hash(), data.hash())
        }
        for value in try [account(extra: 2, code: code, data: data, address: address),
                          account(code: byte(9), data: data, address: address),
                          account(code: code, data: data, address: Address(workchain: 0, hash: Data(repeating: 9, count: 32))),
                          account(code: code, data: data, address: address, split: true),
                          account(code: code, data: data, address: address, trailing: true)] {
            XCTAssertThrowsError(try TOSV5R2AccountState.data(value.toBoc(), expectedAddress: address, expectedCode: code), "Invalid account accepted")
        }
    }
    func testVaultCounterAndImmutableBits() throws {
        let expected = try birth().vaultData
        func changed(_ next: UInt32, flip: Bool = false) throws -> Cell {
            let s = try expected.beginParse(); try s.skip(40)
            let b = try Builder().store(uint: 3, bits: 8).store(uint: next, bits: 32)
            if flip {
                var hash = try s.loadBytes(32); hash[0] ^= 1; try b.store(data: hash)
            }
            return try b.store(slice: s).endCell()
        }
        for next in [UInt32(0), 1, 1048575, 1048576] {
            XCTAssertEqual(try TOSV5R2AccountState.vaultCounter(changed(next), expected: expected), next)
        }
        XCTAssertThrowsError(try TOSV5R2AccountState.vaultCounter(changed(1048577), expected: expected), "Counter overflow accepted")
        XCTAssertThrowsError(try TOSV5R2AccountState.vaultCounter(changed(0, flip: true), expected: expected), "Changed vault bits accepted")
    }
}
