import XCTest
import Foundation
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSQuantumReviewCandidateTests: XCTestCase {
    func testActualCodesArePinnedAndChainIsRestricted() throws {
        let bundle = try TOSQuantumReviewCandidate.load()
        XCTAssertEqual(bundle.codes.wallet.hash(), Data(hex: "18252490f90f12149832b6067ca60f3f0216f23a97d71e7afcd8017eeb75e61f"))
        XCTAssertEqual(TOSQuantumReviewCandidate.minimumVM, 16)
        XCTAssertNoThrow(try TOSQuantumReviewCandidate.requireChain(manifest: Data("{\"network\":\"\(String(repeating: "42", count: 32))\",\"global_id\":1}".utf8)))
        XCTAssertThrowsError(try TOSQuantumReviewCandidate.requireChain(manifest: Data("{\"network\":\"\(String(repeating: "43", count: 32))\",\"global_id\":1}".utf8)))
        XCTAssertThrowsError(try TOSQuantumReviewCandidate.requireChain(manifest: Data("{\"network\":\"\(String(repeating: "42", count: 32))\",\"global_id\":2}".utf8)))
        for value in ["true", "1.2", "\"1\""] {
            XCTAssertThrowsError(try TOSQuantumReviewCandidate.requireChain(manifest: Data("{\"network\":\"\(String(repeating: "42", count: 32))\",\"global_id\":\(value)}".utf8)))
        }
    }
}
