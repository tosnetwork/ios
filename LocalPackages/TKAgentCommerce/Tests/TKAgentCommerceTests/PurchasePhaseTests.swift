import XCTest
@testable import TKAgentCommerce

/// Decodes the SAME shared purchase-phase vector the Go atosbridge phase
/// functions are verified against, so the Swift crash-safe resume logic — the
/// at-most-once payment invariant — is proven identical to the reference and to
/// the Android client.
final class PurchasePhaseTests: XCTestCase {

    private struct Vectors: Decodable {
        let schema: String
        let resume: [Resume]
        let transitions: [Transition]
    }
    private struct Resume: Decodable {
        let phase: String
        let canAcquireLease: Bool
        let resumeAction: String
    }
    private struct Transition: Decodable {
        let from: String
        let to: String
        let canAdvance: Bool
    }

    func testPurchasePhaseMatchesSharedVectors() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "mobile_buyer_purchase_phase_v1", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let vectors = try decoder.decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertEqual(vectors.schema, "atos.native.mobile-buyer-purchase-phase.v1")

        for resume in vectors.resume {
            XCTAssertEqual(PurchasePhase.canAcquireFundingLease(resume.phase), resume.canAcquireLease, resume.phase)
            XCTAssertEqual(PurchasePhase.resumeActionFor(resume.phase).rawValue, resume.resumeAction, resume.phase)
        }
        for transition in vectors.transitions {
            XCTAssertEqual(PurchasePhase.canAdvance(from: transition.from, to: transition.to),
                           transition.canAdvance, "\(transition.from)->\(transition.to)")
        }
    }

    func testNeverRefundsAtOrAfterFundingLease() {
        for phase in ["funding_lease", "funded", "execution", "receipt", "release"] {
            XCTAssertEqual(PurchasePhase.resumeActionFor(phase), .reconcileNeverRefund, phase)
            XCTAssertFalse(PurchasePhase.canAcquireFundingLease(phase), phase)
        }
    }
}
