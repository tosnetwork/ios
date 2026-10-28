import XCTest
import BigInt
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSQuantumPaymentTests: XCTestCase {
    private let recipient = Address(workchain: 0, hash: Data(repeating: 0x42, count: 32))

    func testTOSAmountInputPreservesNanoPrecisionAndRejectsAmbiguousValues() throws {
        for (text, expected) in [("1", "1000000000"), ("0.000000001", "1"),
            ("18446744073.709551617", "18446744073709551617"), ("1.000000000", "1000000000")] {
            XCTAssertEqual(try TOSQuantumPaymentIntent.parseAmount(text).description, expected)
        }
        for text in ["", "0", "0.000000000", "01", ".1", "1.", "1.0000000001", "-1", "+1", "1e2", "1,2", "１", " 1", "1 ", "1..2", String(repeating: "9", count: 40)] {
            XCTAssertThrowsError(try TOSQuantumPaymentIntent.parseAmount(text), text)
        }
    }

    func testNoCommentHasCanonicalHashableEmptyBody() throws {
        let intent = try TOSQuantumPaymentIntent(recipient: recipient, amount: 1, bounce: false)
        let body = try intent.internalMessage().body
        XCTAssertEqual(body.bits.length, 0); XCTAssertTrue(body.refs.isEmpty)
        XCTAssertEqual(body.hash().map { String(format: "%02x", $0) }.joined(),
            "96a296d224f285c67bee93c30f8a309157f0daa35dc5b87e410b78630a09cfc7")
    }

    func testIntentRoundTripKeepsDecimalPrecisionAndRejectsNoncanonicalInputs() throws {
        let amount = try XCTUnwrap(BigUInt("18446744073709551617"))
        let intent = try TOSQuantumPaymentIntent(recipient: recipient, amount: amount, bounce: false, comment: "付款 🌸")
        let data = try JSONEncoder().encode(intent)
        XCTAssertEqual(try JSONDecoder().decode(TOSQuantumPaymentIntent.self, from: data), intent)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["amount"] as? String, "18446744073709551617")
        for invalid in ["01", "+1", "-1", "1.0", "0", String(BigUInt(1) << 120)] {
            json["amount"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(TOSQuantumPaymentIntent.self,
                from: JSONSerialization.data(withJSONObject: json)))
        }
        json["amount"] = "1"; json["version"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(TOSQuantumPaymentIntent.self,
            from: JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try TOSQuantumPaymentIntent(recipient: recipient, amount: 1, bounce: true,
            comment: String(repeating: "🌸", count: 1025)))
    }

    func testActionContainsExactRecipientValueBounceAndUTF8Comment() throws {
        let text = "Payment\n付款🌸", amount = BigUInt(UInt64.max) + 2
        for bounce in [false, true] {
            let intent = try TOSQuantumPaymentIntent(recipient: recipient, amount: amount, bounce: bounce, comment: text)
            let s = try intent.actions().beginParse()
            XCTAssertEqual(try s.loadUint(bits: 32), 0x0ec3c86d)
            XCTAssertEqual(try s.loadUint(bits: 8), 3)
            let end = try s.loadRef().beginParse()
            XCTAssertEqual(end.remainingBits, 0); XCTAssertEqual(end.remainingRefs, 0)
            let message: MessageRelaxed = try s.loadRef().beginParse().loadType()
            try s.endParse()
            guard case .internalInfo(let info) = message.info else { return XCTFail("Expected internal transfer") }
            XCTAssertEqual(info.dest, recipient); XCTAssertEqual(info.value.coins.rawValue, amount)
            XCTAssertEqual(info.bounce, bounce); XCTAssertFalse(info.bounced); XCTAssertTrue(info.ihrDisabled)
            XCTAssertNil(message.stateInit)
            let body = try message.body.beginParse()
            XCTAssertEqual(try body.loadUint(bits: 32), 0)
            XCTAssertEqual(try body.loadSnakeData(), Data(text.utf8))
        }
    }

    func testCanonicallyEquivalentUnicodeStillPreservesDistinctWireBytes() throws {
        let composed = "é", decomposed = "e\u{301}"
        XCTAssertEqual(composed, decomposed) // Swift String equality normalizes Unicode.
        let first = try TOSQuantumPaymentIntent(recipient: recipient, amount: 1, bounce: false, comment: composed)
        let second = try TOSQuantumPaymentIntent(recipient: recipient, amount: 1, bounce: false, comment: decomposed)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(try first.actions().hash(), try second.actions().hash())
        let decoded = try JSONDecoder().decode(TOSQuantumPaymentIntent.self, from: JSONEncoder().encode(second))
        XCTAssertEqual(decoded, second)
        XCTAssertEqual(decoded.comment.map { Data($0.utf8) }, Data(decomposed.utf8))
    }

    func testIntentCannotDescribeAnotherAuthorizationOrRescueOperation() throws {
        let authority = try TOSQuantumSelfPayAuthority(globalID: 42, namespace: Data(repeating: 1, count: 32),
            primaryKey: Data(repeating: 2, count: 1312), rescueKey: Data(repeating: 3, count: 32))
        let wallet = try TOSQuantumSelfPayWallet(authority: authority)
        let intent = try TOSQuantumPaymentIntent(recipient: recipient, amount: 10, bounce: true, comment: "visible")
        // A raw rescue codec is deliberately not a confirmed PRIMARY payment.
        let rescue = try TOSQuantumSelfPayRequest(wallet: wallet.address,
            state: TOSQuantumSelfPayState(authority: authority), role: .rescue,
            validUntil: 120, action: .execute(intent.actions()), provenTime: 1)
        XCTAssertThrowsError(try intent.requireBound(request: rescue.request, role: .rescue))
        let forgedKind = try Builder().store(data: Data(count: 126)).store(uint: 0, bits: 3).store(uint: 3, bits: 8)
            .store(ref: Builder().store(uint: 0x45584543, bits: 32).store(ref: intent.actions())).endCell()
        XCTAssertThrowsError(try intent.requireBound(request: forgedKind, role: .primary))
    }
}
