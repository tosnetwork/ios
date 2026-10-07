import XCTest
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSV5R2InstalledRouteTests: XCTestCase {
    private func byte(_ n: UInt8) throws -> Cell { try Builder().store(uint: n, bits: 8).endCell() }
    private func birth(network: UInt8 = 0x42, global: Int32 = 1, moduleCode: UInt8 = 2, vaultCode: UInt8 = 3, tree: UInt8 = 0) throws -> TOSV5R2Genesis {
        let codes = try TOSV5R2Codes(wallet: byte(1), module: byte(moduleCode), vault: byte(vaultCode))
        var fee = Data(count: 60); fee.replaceSubrange(0..<12, with: [0,0,0,1,0,0,0,8,0,0,0,3])
        return try TOSV5R2Genesis(codes: codes,
            pins: TOSV5R2CodePins(wallet: codes.wallet.hash(), module: codes.module.hash(), vault: codes.vault.hash()),
            globalId: global, network: Data(repeating: network, count: 32), walletId: 17,
            primaryKey: Data(repeating: tree, count: 1312), rescueKey: Data(repeating: tree, count: 32), policy: .ready,
            feeTreeId: Data(repeating: tree, count: 32), feePublicKey: fee, epoch0: 100)
    }
    func testInitialAndSuccessorKeepOriginalWallet() throws {
        let original = try birth(), next = try birth(tree: 1)
        XCTAssertEqual(TOSV5R2InstalledRoute.initial(original).vaultInit.hash(), original.vaultInit.hash())
        let route = try TOSV5R2InstalledRoute.successor(birth: original, next: next)
        XCTAssertEqual(route.moduleInit.hash(), next.moduleInit.hash())
        XCTAssertEqual(route.vaultInit.hash(), try next.successorFor(wallet: original.address).vaultInit.hash(), "Successor vault changed original wallet")
        XCTAssertNotEqual(route.vaultInit.hash(), next.vaultInit.hash())
        let refs = try route.vaultData.beginParse(); _ = try refs.loadRef()
        let prefix = try refs.loadRef().beginParse(); try prefix.skip(320)
        let wallet: Address = try prefix.loadType()
        XCTAssertEqual(wallet, original.address)
    }
    func testIncompatibleNamespaceAndCodeRefuse() throws {
        let original = try birth()
        for next in try [birth(network: 0x43), birth(global: 2), birth(moduleCode: 9), birth(vaultCode: 9)] {
            XCTAssertThrowsError(try TOSV5R2InstalledRoute.successor(birth: original, next: next), "Incompatible successor accepted")
        }
    }
    func testCustodyFollowsCurrentModuleInsteadOfBirthKey() throws {
        let original = try birth(), next = try birth(tree: 1)
        try TOSV5R2InstalledRoute.initial(original).requirePrimaryKey(Data(count: 1312))
        let current = try TOSV5R2InstalledRoute.successor(birth: original, next: next)
        try current.requirePrimaryKey(Data(repeating: 1, count: 1312))
        XCTAssertThrowsError(try current.requirePrimaryKey(Data(count: 1312)), "Birth key accepted after rotation")
        XCTAssertThrowsError(try current.requirePrimaryKey(Data(count: 32)), "Wrong key size accepted")
    }
}
