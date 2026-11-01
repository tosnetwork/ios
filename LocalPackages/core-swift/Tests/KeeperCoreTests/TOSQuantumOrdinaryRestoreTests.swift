import XCTest
@testable import KeeperCore

/// State policy fixtures, not authenticated proof, custody or end-to-end acceptance.
final class TOSQuantumOrdinaryRestoreTests: XCTestCase {
    private func authority(primary: UInt8 = 11) throws -> TOSQuantumSelfPayAuthority {
        try TOSQuantumSelfPayAuthority(globalID: 1, namespace: Data(repeating: 42, count: 32),
            primaryKey: Data(repeating: primary, count: 1312), rescueKey: Data(repeating: 12, count: 32))
    }

    func testCurrentNonzeroCountersAndUndeployedWalletsAreUsable() throws {
        let auth = try authority()
        let identity = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: auth))
        let state = try TOSQuantumSelfPayState(authority: auth, walletID: identity.wallet.walletID,
            seqno: 7, epoch: 3, primaryNonce: 9, rescueNonce: 4)
        XCTAssertNoThrow(try TOSQuantumOrdinaryRestore.requireUsable(identity: identity, status: .active(state)))
        XCTAssertNoThrow(try TOSQuantumOrdinaryRestore.requireUsable(identity: identity, status: .absent))
        XCTAssertNoThrow(try TOSQuantumOrdinaryRestore.requireUsable(identity: identity, status: .uninitialized))
    }

    func testChangedAuthorityRetirementIdentityAndExhaustionAreRejected() throws {
        let auth = try authority()
        let identity = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: auth))
        let states = try [
            TOSQuantumSelfPayState(authority: authority(primary: 21), walletID: identity.wallet.walletID),
            TOSQuantumSelfPayState(authority: auth, walletID: identity.wallet.walletID, retired: 2),
            TOSQuantumSelfPayState(authority: auth, walletID: identity.wallet.walletID ^ 1),
            TOSQuantumSelfPayState(authority: auth, walletID: identity.wallet.walletID, seqno: .max),
            TOSQuantumSelfPayState(authority: auth, walletID: identity.wallet.walletID, primaryNonce: .max)
        ]
        for state in states {
            XCTAssertThrowsError(try TOSQuantumOrdinaryRestore.requireUsable(identity: identity, status: .active(state)))
        }
    }

    func testFrozenAccountRequiresSeparateRecovery() throws {
        let identity = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: authority()))
        XCTAssertThrowsError(try TOSQuantumOrdinaryRestore.requireUsable(identity: identity, status: .frozen(Data(repeating: 0, count: 32))))
    }
}
