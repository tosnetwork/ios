import XCTest
@testable import TKAgentCommerce

/// These tests decode the shared escrow v2 projection vectors, which the Android
/// client decodes identically. The five status cases carry the fields of the
/// data cells the escrow v2 contract itself wrote in the TOS sandbox; the
/// refusal cases edit one field of such a case (see the file's provenance).
final class EscrowProjectionTests: XCTestCase {

    private struct Vectors: Decodable {
        let schema: String
        let escrowStatus: [String: UInt8]
        let quotedAtomic: String
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let present: Bool
        let escrow: Escrow?
        let fundingView: FundingExpectation?
        let settlementView: SettlementExpectation?
        let exactlyFundedAtQuote: Bool?
        let expectError: String?
    }

    private struct Escrow: Decodable {
        let status: UInt8
        let quoteCommitment: String
        let fundedAtomicAmount: String
        let settledAtomicAmount: String
        let receiptCommitment: String
        let acceptedAtUnix: UInt64
        let pendingQueryId: UInt64
    }

    private struct FundingExpectation: Decodable {
        let found: Bool
        let pendingAcceptance: Bool
        let awaitingFunding: Bool
        let fundedAtomic: String
        let settledAtomic: String
        let receiptCommitment: String
    }

    private struct SettlementExpectation: Decodable {
        let released: Bool
        let refunded: Bool
        let providerCreditAtomic: String
    }

    private func loadVectors() throws -> Vectors {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "mobile_buyer_escrow_projection_v2", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Vectors.self, from: Data(contentsOf: url))
    }

    private func runtime(_ testCase: Case) -> EscrowRuntimeState? {
        guard testCase.present, let escrow = testCase.escrow else { return nil }
        return EscrowRuntimeState(status: escrow.status, quoteCommitment: escrow.quoteCommitment,
                                  fundedAtomicAmount: escrow.fundedAtomicAmount,
                                  settledAtomicAmount: escrow.settledAtomicAmount,
                                  receiptCommitment: escrow.receiptCommitment,
                                  acceptedAtUnix: escrow.acceptedAtUnix,
                                  pendingQueryID: escrow.pendingQueryId)
    }

    private func errorKind(_ error: Error) -> String {
        switch error {
        case EscrowStateError.unsupportedStatus: return "unsupported_status"
        case EscrowStateError.inconsistentState: return "inconsistent_state"
        case EscrowStateError.malformedCommitment: return "malformed_commitment"
        case AtomicAmountError.notCanonical: return "malformed_amount"
        default: return "unexpected: \(error)"
        }
    }

    private func vectorCase(_ vectors: Vectors, _ name: String) throws -> Case {
        try XCTUnwrap(vectors.cases.first { $0.name == name }, "missing case \(name)")
    }

    func testStatusValuesAreTheContractStatuses() throws {
        let vectors = try loadVectors()
        XCTAssertEqual(vectors.schema, "tos.service.mobile-buyer-escrow-projection.v2")
        let expected: [String: EscrowStatus] = [
            "pending_acceptance": .pendingAcceptance,
            "awaiting_funding": .awaitingFunding,
            "funded": .funded,
            "release_pending": .releasePending,
            "refund_pending": .refundPending,
        ]
        XCTAssertEqual(Set(vectors.escrowStatus.keys), Set(expected.keys))
        for (name, status) in expected {
            XCTAssertEqual(vectors.escrowStatus[name], status.rawValue, name)
        }
    }

    func testEveryContractStatusIsCovered() throws {
        let vectors = try loadVectors()
        var covered = Set<UInt8>()
        for testCase in vectors.cases where testCase.expectError == nil {
            if let escrow = testCase.escrow { covered.insert(escrow.status) }
        }
        XCTAssertEqual(covered, Set(0...4))
    }

    func testProjectionMatchesSharedVectors() throws {
        let vectors = try loadVectors()
        let quoted = try parseAtomicAmount(vectors.quotedAtomic)
        XCTAssertFalse(vectors.cases.isEmpty)

        for testCase in vectors.cases {
            let state = runtime(testCase)

            if let want = testCase.expectError {
                for (label, call) in [
                    ("funding", { _ = try EscrowProjection.funding(state) }),
                    ("settlement", { _ = try EscrowProjection.settlement(state) }),
                    ("isExactlyFunded", { _ = try EscrowProjection.isExactlyFunded(state, quotedAtomic: quoted) }),
                ] as [(String, () throws -> Void)] {
                    XCTAssertThrowsError(try call(), "\(testCase.name) \(label) must refuse") { error in
                        XCTAssertEqual(errorKind(error), want, "\(testCase.name) \(label)")
                    }
                }
                continue
            }

            let funding = try EscrowProjection.funding(state)
            let settlement = try EscrowProjection.settlement(state)
            let wantFunding = try XCTUnwrap(testCase.fundingView, testCase.name)
            let wantSettlement = try XCTUnwrap(testCase.settlementView, testCase.name)

            XCTAssertEqual(funding.found, wantFunding.found, testCase.name)
            XCTAssertEqual(funding.pendingAcceptance, wantFunding.pendingAcceptance, testCase.name)
            XCTAssertEqual(funding.awaitingFunding, wantFunding.awaitingFunding, testCase.name)
            XCTAssertEqual(funding.fundedAtomic, try parseAtomicAmount(wantFunding.fundedAtomic), testCase.name)
            XCTAssertEqual(funding.settledAtomic, try parseAtomicAmount(wantFunding.settledAtomic), testCase.name)
            XCTAssertEqual(funding.receiptCommitment, wantFunding.receiptCommitment, testCase.name)

            XCTAssertEqual(settlement.released, wantSettlement.released, testCase.name)
            XCTAssertEqual(settlement.refunded, wantSettlement.refunded, testCase.name)
            XCTAssertEqual(settlement.providerCreditAtomic,
                           try parseAtomicAmount(wantSettlement.providerCreditAtomic), testCase.name)

            XCTAssertEqual(try EscrowProjection.isExactlyFunded(state, quotedAtomic: quoted),
                           try XCTUnwrap(testCase.exactlyFundedAtQuote, testCase.name), testCase.name)
        }
    }

    func testFundedIsNeverReleased() throws {
        let vectors = try loadVectors()
        let funded = try XCTUnwrap(runtime(try vectorCase(vectors, "funded")))
        XCTAssertEqual(funded.status, EscrowStatus.funded.rawValue)
        let settlement = try EscrowProjection.settlement(funded)
        XCTAssertFalse(settlement.released)
        XCTAssertFalse(settlement.refunded)
        XCTAssertEqual(settlement.providerCreditAtomic, 0)
        XCTAssertFalse(try EscrowProjection.funding(funded).awaitingFunding)
        XCTAssertTrue(try EscrowProjection.isExactlyFunded(funded, quotedAtomic: 25_000_000))
        XCTAssertFalse(try EscrowProjection.isExactlyFunded(funded, quotedAtomic: 24_999_999))
    }

    func testSettlementInProgressIsNotDispatchable() throws {
        let vectors = try loadVectors()
        for name in ["release_pending", "refund_pending"] {
            let state = try XCTUnwrap(runtime(try vectorCase(vectors, name)))
            XCTAssertEqual(state.fundedAtomicAmount, "25000000", name)
            XCTAssertFalse(try EscrowProjection.isExactlyFunded(state, quotedAtomic: 25_000_000), name)
        }
    }

    func testMissingEscrowIsNotFundable() throws {
        let funding = try EscrowProjection.funding(nil)
        XCTAssertFalse(funding.found)
        XCTAssertFalse(funding.awaitingFunding)
        XCTAssertFalse(funding.pendingAcceptance)
        XCTAssertFalse(try EscrowProjection.isExactlyFunded(nil, quotedAtomic: 25_000_000))
    }

    func testOverflowAmountIsRejected() {
        XCTAssertThrowsError(try parseAtomicAmount("18446744073709551616"))
    }
}
