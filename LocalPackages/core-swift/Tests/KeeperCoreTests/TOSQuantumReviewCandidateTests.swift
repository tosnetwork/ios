import XCTest
import Foundation
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSQuantumReviewCandidateTests: XCTestCase {
    func testActualCodesArePinnedAndChainIsRestricted() throws {
        let bundle = try TOSQuantumReviewCandidate.load()
        XCTAssertEqual(bundle.codes.wallet.hash(), Data(hex: "06203e98d4d8bf97b0cab37523ec435f5ab0e1d6d2c5253926eebf20ef1712f5"))
        XCTAssertEqual(TOSQuantumReviewCandidate.minimumVM, 18)
        XCTAssertNoThrow(try TOSQuantumReviewCandidate.requireChain(manifest: Data("{\"network\":\"\(String(repeating: "42", count: 32))\",\"global_id\":1}".utf8)))
        XCTAssertThrowsError(try TOSQuantumReviewCandidate.requireChain(manifest: Data("{\"network\":\"\(String(repeating: "43", count: 32))\",\"global_id\":1}".utf8)))
        XCTAssertThrowsError(try TOSQuantumReviewCandidate.requireChain(manifest: Data("{\"network\":\"\(String(repeating: "42", count: 32))\",\"global_id\":2}".utf8)))
        for value in ["true", "1.2", "\"1\""] {
            XCTAssertThrowsError(try TOSQuantumReviewCandidate.requireChain(manifest: Data("{\"network\":\"\(String(repeating: "42", count: 32))\",\"global_id\":\(value)}".utf8)))
        }
    }
}
