import XCTest
import BigInt
@testable import KeeperCore

final class NativeBalanceAmountTests: XCTestCase {
    func testMaximumCoinAmountSurvivesDecimalJSONAndProcessedPresentation() throws {
        let maximum = (BigUInt(1) << 120) - 1
        let original = TonBalance(amount: maximum)
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "{\"amount\":\"\(maximum)\"}")
        XCTAssertEqual(try JSONDecoder().decode(TonBalance.self, from: encoded).amount, maximum)
        let processed = ProcessedBalanceTonItem(id: "TOS", title: "TOS", amount: maximum,
            fractionalDigits: 9, currency: .TON, converted: 0, price: 1, diff: nil, shouldCalculateInTotal: true)
        XCTAssertEqual(try JSONDecoder().decode(ProcessedBalanceTonItem.self,
            from: JSONEncoder().encode(processed)).amount, maximum)
        let rate = Rates.Rate(currency: .TON, rate: 1, diff24h: nil)
        let scaled = RateConverter().convert(amount: original.amount, amountFractionLength: 9, rate: rate)
        XCTAssertEqual(scaled.amount, maximum)
        XCTAssertEqual(scaled.fractionLength, 9)
    }

    func testOldNumericCacheRemainsReadableWithoutTruncation() throws {
        for value in ["0", "9223372036854775807", "18446744073709551615"] {
            let data = Data("{\"amount\":\(value)}".utf8)
            XCTAssertEqual(try JSONDecoder().decode(TonBalance.self, from: data).amount, BigUInt(value))
        }
    }

    func testMalformedOrOutOfRangeAmountsAreRefused() {
        let tooLarge = BigUInt(1) << 120
        for json in ["{\"amount\":-1}", "{\"amount\":1.5}", "{\"amount\":\"\(tooLarge)\"}",
                     "{\"amount\":\"01\"}", "{\"amount\":\"+1\"}", "{\"amount\":\" 1\"}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(TonBalance.self, from: Data(json.utf8)))
        }
    }
}
