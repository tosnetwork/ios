import BigInt
@testable import KeeperCore
import XCTest

final class AmountFormatterTests: XCTestCase {
    private let formatter = AmountFormatter(configuration: .init(locale: Locale(identifier: "en_US_POSIX")))

    func testFormatsNativeTOSNanoAmountsExactly() {
        XCTAssertEqual(formatter.format(amount: 0, fractionDigits: 9, style: .exactValue), "0")
        XCTAssertEqual(formatter.format(amount: 1, fractionDigits: 9, style: .exactValue), "0.000000001")
        XCTAssertEqual(formatter.format(amount: 1_000_000_000, fractionDigits: 9, style: .exactValue), "1")
        XCTAssertEqual(formatter.format(amount: 1_234_567_890, fractionDigits: 9, style: .exactValue), "1.23456789")
    }

    func testCompactFormattingUsesBoundedPrecisionWithoutRoundingUp() {
        XCTAssertEqual(formatter.format(amount: 999_999_999, fractionDigits: 9), "0.999")
        XCTAssertEqual(formatter.format(amount: 15_459_999_999, fractionDigits: 9), "15.45")
        XCTAssertEqual(formatter.format(amount: 999_999_999_999, fractionDigits: 9), "999.99")
        XCTAssertEqual(formatter.format(amount: 1_000_999_999_999, fractionDigits: 9), "1,000")
    }

    func testVeryLargeNativeTOSAmountDoesNotOverflowOrTruncateIntegerDigits() throws {
        let amount = try XCTUnwrap(BigUInt("123456789012345678901234567890123456789"))
        XCTAssertEqual(
            formatter.format(amount: amount, fractionDigits: 9, style: .exactValue),
            "123,456,789,012,345,678,901,234,567,890.123456789"
        )
    }

    func testNativeTOSAccessoryUsesTOSSymbol() {
        XCTAssertEqual(
            formatter.format(amount: 1_500_000_000, fractionDigits: 9, accessory: .symbol("TOS"), style: .exactValue),
            "1.5\u{2009}TOS"
        )
    }
}
