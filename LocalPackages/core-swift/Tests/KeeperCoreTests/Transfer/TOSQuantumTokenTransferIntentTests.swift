import XCTest
import Foundation
import BigInt
import TonSwift
@testable import KeeperCore

final class TOSQuantumTokenTransferIntentTests: XCTestCase {
    private func address(_ hex: String) throws -> Address { try Address.parse("0:" + String(repeating: hex, count: 32)) }
    private func intent(units: BigUInt = 9_007_199_254_740_993, decimals: Int = 6, queryId: UInt64 = .max,
                        attached: BigUInt = 100_000_000, forward: BigUInt = 0, destination: Address? = nil,
                        wrongWallet: Bool = false) throws -> TOSQuantumTokenTransferIntent {
        let owner = try address("11"), master = try address("22")
        let wallet = try TOSTokenWalletState.address(owner: owner, master: master, walletCode: TOSTokenContractCodes.nativeWallet())
        return try TOSQuantumTokenTransferIntent(owner: owner, master: master, wallet: wrongWallet ? address("44") : wallet,
            recipient: destination ?? address("33"), units: units, decimals: decimals, queryId: queryId, attachedTos: attached, forwardTos: forward)
    }
    private func fixture(_ name: String) throws -> Cell {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "boc", subdirectory: "quantum-payment"))
        return try XCTUnwrap(Cell.fromBoc(src: Data(contentsOf: url)).first)
    }
    func testBodyEnvelopeAndActionsMatchIndependentFiftAtUnsigned64Maximum() throws {
        let value = try intent()
        XCTAssertEqual(try value.body().hash(), try fixture("token-transfer-intent-body").hash())
        XCTAssertEqual(try value.message().hash(), try fixture("token-transfer-intent-message").hash())
        XCTAssertEqual(try value.actions().hash(), try fixture("token-transfer-intent-actions").hash())
    }
    func testExactPersistentFieldsRejectCorruptAmountsAndBindings() throws {
        let value = try intent(units: (BigUInt(1) << 120) - 1, decimals: 255)
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(TOSQuantumTokenTransferIntent.self, from: encoded), value)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (key, bad) in [("version", 2 as Any), ("units", 1 as Any), ("units", "01" as Any),
                           ("queryId", "18446744073709551616" as Any), ("attachedTos", "0" as Any),
                           ("decimals", 256 as Any), ("wallet", "0:" + String(repeating: "44", count: 32) as Any)] {
            var changed = original; changed[key] = bad
            XCTAssertThrowsError(try JSONDecoder().decode(TOSQuantumTokenTransferIntent.self,
                from: JSONSerialization.data(withJSONObject: changed)))
        }
    }
    func testActionFieldsBindUnitsAddressesQueryAndNativeBudget() throws {
        let base = try intent()
        let variants = try [intent(units: base.units + 1), intent(queryId: 0), intent(attached: base.attachedTos + 1),
                            intent(forward: 1), intent(destination: address("11"))]
        for changed in variants {
            XCTAssertNotEqual(try base.actions().hash(), try changed.actions().hash())
        }
        let precision = try intent(decimals: 9)
        XCTAssertNotEqual(base, precision)
        XCTAssertEqual(try base.actions().hash(), try precision.actions().hash())
    }
    func testPaymentIntentPersistsTokenAndRejectsConflictingOuterEnvelope() throws {
        let token = try intent()
        let payment = TOSQuantumPaymentIntent(tokenTransfer: token)
        XCTAssertEqual(try payment.actions().hash(), try token.actions().hash())
        let data = try JSONEncoder().encode(payment)
        XCTAssertEqual(try JSONDecoder().decode(TOSQuantumPaymentIntent.self, from: data), payment)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, bad) in [("recipient", try address("33").toRaw() as Any),
                           ("amount", "1" as Any), ("bounce", false as Any), ("comment", "unexpected" as Any)] {
            var changed = original; changed[key] = bad
            XCTAssertThrowsError(try JSONDecoder().decode(TOSQuantumPaymentIntent.self,
                from: JSONSerialization.data(withJSONObject: changed)))
        }
        let native = try TOSQuantumPaymentIntent(recipient: address("33"), amount: 1, bounce: false)
        XCTAssertNil(try JSONDecoder().decode(TOSQuantumPaymentIntent.self,
            from: JSONEncoder().encode(native)).tokenTransfer)
    }

    func testInvalidAmountsWalletAndWorkchainDoNotProduceRequests() throws {
        XCTAssertThrowsError(try intent(units: 0))
        XCTAssertThrowsError(try intent(units: BigUInt(1) << 120))
        XCTAssertThrowsError(try intent(decimals: -1))
        XCTAssertThrowsError(try intent(attached: 0))
        XCTAssertThrowsError(try intent(forward: 100_000_000))
        XCTAssertThrowsError(try intent(wrongWallet: true))
        XCTAssertThrowsError(try intent(destination: Address.parse("-1:" + String(repeating: "33", count: 32))))
    }
}
