import BigInt
@testable import KeeperCore
import TonSwift
import XCTest

final class TOSTokenWalletStateTests: XCTestCase {
    private let owner = try! Address.parse("0:" + String(repeating: "11", count: 32))
    private let master = try! Address.parse("0:" + String(repeating: "22", count: 32))
    private func code(_ value: UInt64 = 1) throws -> Cell { try Builder().store(uint: value, bits: 8).endCell() }
    private func data(amount: BigUInt = 0, owner: Address? = nil, master: Address? = nil,
                      storedCode: Cell? = nil, trailing: Bool = false) throws -> Cell {
        let bytes = (amount.bitWidth + 7) / 8
        let builder = try Builder().store(uint: bytes, bits: 4)
        if bytes > 0 { try builder.store(biguint: amount, bits: bytes * 8) }
        try builder.store(owner ?? self.owner).store(master ?? self.master).store(ref: storedCode ?? code())
        if trailing { try builder.store(bit: false) }
        return try builder.endCell()
    }
    func testPreservesZeroAndMaximumUnsignedBalance() throws {
        let wallet = try TOSTokenWalletState.address(owner: owner, master: master, walletCode: code())
        for value in [BigUInt(0), BigUInt(1), (BigUInt(1) << 120) - 1] {
            let state = try TOSTokenWalletState.decode(data(amount: value), wallet: wallet, owner: owner, master: master, walletCode: code())
            XCTAssertEqual(state.balance, value)
            XCTAssertEqual(state.owner, owner); XCTAssertEqual(state.master, master)
        }
    }
    func testWrongOwnerMasterCodeAndTrailingStorageAreRefused() throws {
        let wallet = try TOSTokenWalletState.address(owner: owner, master: master, walletCode: code())
        for value in [try data(owner: master), try data(master: owner), try data(storedCode: code(2)), try data(trailing: true)] {
            XCTAssertThrowsError(try TOSTokenWalletState.decode(value, wallet: wallet, owner: owner, master: master, walletCode: code()))
        }
        XCTAssertThrowsError(try TOSTokenWalletState.decode(data(), wallet: owner, owner: owner, master: master, walletCode: code()))
        XCTAssertThrowsError(try TOSTokenWalletState.decode(data(), wallet: wallet, owner: owner, master: master, walletCode: code(2)))
    }
    func testAddressDerivationBindsBothIdentitiesAndCode() throws {
        let wallet = try TOSTokenWalletState.address(owner: owner, master: master, walletCode: code())
        XCTAssertNotEqual(wallet, try TOSTokenWalletState.address(owner: master, master: master, walletCode: code()))
        XCTAssertNotEqual(wallet, try TOSTokenWalletState.address(owner: owner, master: owner, walletCode: code()))
        XCTAssertNotEqual(wallet, try TOSTokenWalletState.address(owner: owner, master: master, walletCode: code(2)))
        XCTAssertThrowsError(try TOSTokenWalletState.address(owner: Address.parse("-1:" + String(repeating: "11", count: 32)), master: master, walletCode: code()))
    }
    func testStandardTokenAddressMatchesIndependentFiftVector() throws {
        func fixture(_ name: String) throws -> Cell {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "boc", subdirectory: "quantum-payment"))
            let cells = try Cell.fromBoc(src: Data(contentsOf: url))
            XCTAssertEqual(cells.count, 1)
            return try XCTUnwrap(cells.first)
        }
        let code = try fixture("token-wallet-code")
        let expected = try Address.parse("0:4377841593b86fb71d29b1306cebd8b1dcaf7071e4a32ed206c5932388c60dae")
        XCTAssertEqual(try TOSTokenWalletState.address(owner: owner, master: master, walletCode: code), expected)
        XCTAssertEqual(try TOSTokenWalletState.decode(fixture("token-wallet-data"), wallet: expected, owner: owner, master: master, walletCode: code).balance, 0)
    }

}
