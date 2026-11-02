import BigInt
@testable import KeeperCore
import XCTest

final class TOSTokenAmountTests: XCTestCase {
    func testExactUnitsRoundTripAcrossSupportedPrecision() throws {
        let maximum = (BigUInt(1) << 120) - 1
        for decimals in [0, 6, 9, 18, 255] {
            for units in [BigUInt(1), BigUInt("9007199254740993")!, maximum] {
                XCTAssertEqual(try TOSTokenAmount.parse(TOSTokenAmount.format(units, decimals: decimals), decimals: decimals), units)
            }
            XCTAssertEqual(try TOSTokenAmount.format(0, decimals: decimals), "0")
        }
        XCTAssertEqual(try TOSTokenAmount.parse("1.234567", decimals: 6), 1_234_567)
        XCTAssertEqual(try TOSTokenAmount.format(1_230_000, decimals: 6), "1.23")
    }

    func testAmbiguousAndOutOfRangeInputsAreRejected() {
        for text in ["0", "0.0", "-1", "+1", "01", ".1", "1.", "1e3", " 1", "1,2", "١", "1.0000001"] {
            XCTAssertThrowsError(try TOSTokenAmount.parse(text, decimals: 6), text)
        }
        XCTAssertThrowsError(try TOSTokenAmount.parse("1.0", decimals: 0))
        XCTAssertThrowsError(try TOSTokenAmount.parse("1", decimals: -1))
        XCTAssertThrowsError(try TOSTokenAmount.format(1, decimals: 256))
        XCTAssertThrowsError(try TOSTokenAmount.parse(String(BigUInt(1) << 120), decimals: 0))
    }
}
