import BigInt
@testable import KeeperCore
import TonSwift
import XCTest

final class TOSTokenMasterStateTests: XCTestCase {
    private func content() throws -> Cell { try Builder().store(uint: 1, bits: 8).store(data: Data("https://example.invalid/token.json".utf8)).endCell() }
    private func data(supply: BigUInt = 0, admin: Bool = false, wrongCode: Bool = false, trailing: Bool = false) throws -> Cell {
        let bytes = (supply.bitWidth + 7) / 8
        let b = try Builder().store(uint: bytes, bits: 4)
        if bytes > 0 { try b.store(biguint: supply, bits: bytes * 8) }
        if admin { try b.store(Address.parse("0:" + String(repeating: "33", count: 32))) }
        else { try b.store(uint: 0, bits: 2) }
        try b.store(ref: content()).store(ref: wrongCode ? Builder().endCell() : TOSTokenContractCodes.referenceWallet())
        if trailing { try b.store(ref: content()) }
        return try b.endCell()
    }
    func testSupplyAndContentSurviveMintAdminRenunciation() throws {
        for admin in [false, true] {
            for supply in [BigUInt(0), (BigUInt(1) << 120) - 1] {
                let state = try TOSTokenMasterState.decode(data(supply: supply, admin: admin), expectedWalletCode: TOSTokenContractCodes.referenceWallet())
                XCTAssertEqual(state.totalSupply, supply)
                XCTAssertEqual(state.content.hash(), try content().hash())
            }
        }
    }
    func testWrongWalletCodeAndTrailingStorageAreRejected() throws {
        XCTAssertThrowsError(try TOSTokenMasterState.decode(data(wrongCode: true), expectedWalletCode: TOSTokenContractCodes.referenceWallet()))
        XCTAssertThrowsError(try TOSTokenMasterState.decode(data(trailing: true), expectedWalletCode: TOSTokenContractCodes.referenceWallet()))
    }
    func testRuntimeReferenceWalletPinMatchesIndependentFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "token-wallet-code", withExtension: "boc", subdirectory: "quantum-payment"))
        let fixture = try XCTUnwrap(Cell.fromBoc(src: Data(contentsOf: url)).first)
        XCTAssertEqual(fixture.hash(), try TOSTokenContractCodes.referenceWallet().hash())
        XCTAssertNotEqual(try TOSTokenContractCodes.referenceMaster().hash(), fixture.hash())
    }
    func testNativeFamilyPinsAndDerivedAddressMatchIndependentFift() throws {
        func fixture(_ name: String) throws -> Cell {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "boc", subdirectory: "quantum-payment"))
            return try XCTUnwrap(Cell.fromBoc(src: Data(contentsOf: url)).first)
        }
        let owner = try Address.parse("0:" + String(repeating: "11", count: 32))
        let master = try Address.parse("0:" + String(repeating: "22", count: 32))
        let wallet = try Address.parse("0:5c2e7defab4c288bc81524d1594af7a14a984c4d789ac2acf28a4e8b589f9293")
        let code = try TOSTokenContractCodes.nativeWallet()
        XCTAssertEqual(try fixture("token-wallet-tol").hash(), code.hash())
        XCTAssertEqual(try fixture("token-minter-tol").hash(), try TOSTokenContractCodes.nativeMaster().hash())
        XCTAssertEqual(try TOSTokenWalletState.address(owner: owner, master: master, walletCode: code), wallet)
        XCTAssertEqual(try TOSTokenWalletState.decode(fixture("token-native-wallet-data"), wallet: wallet, owner: owner, master: master, walletCode: code).balance, 0)
        XCTAssertEqual(try TOSTokenContractCodes.family(owner: owner, master: master, wallet: wallet).name, "native-tol-v1")
        let reference = try TOSTokenWalletState.address(owner: owner, master: master, walletCode: TOSTokenContractCodes.referenceWallet())
        XCTAssertEqual(try TOSTokenContractCodes.family(owner: owner, master: master, wallet: reference).name, "sdk-func-v1")
        XCTAssertThrowsError(try TOSTokenContractCodes.family(owner: master, master: master, wallet: wallet))
    }

}
