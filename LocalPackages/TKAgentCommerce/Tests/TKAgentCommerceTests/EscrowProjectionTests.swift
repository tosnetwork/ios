import XCTest
@testable import TKAgentCommerce

/// These tests decode the SAME shared vector file the Go EscrowSettlementReader
/// is verified against, so the Swift projection is proven identical to the
/// canonical implementation and to the Android client.
final class EscrowProjectionTests: XCTestCase {

    private struct Vectors: Decodable {
        let schema: String
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let present: Bool
        let escrow: Escrow?
        let fundingView: FundingExpectation?
        let settlementView: SettlementExpectation?
        let expectDecodeError: Bool?
    }

    private struct Escrow: Decodable {
        let status: UInt8
        let quoteCommitment: String
        let fundedAtomicAmount: String
        let settledAtomicAmount: String
        let receiptCommitment: String
    }

    private struct FundingExpectation: Decodable {
        let found: Bool
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
            forResource: "mobile_buyer_escrow_projection_v1", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testProjectionMatchesSharedVectors() throws {
        let vectors = try loadVectors()
        XCTAssertEqual(vectors.schema, "tos.service.mobile-buyer-escrow-projection.v1")
        XCTAssertFalse(vectors.cases.isEmpty)

        for testCase in vectors.cases {
            let runtime = testCase.present ? testCase.escrow.map {
                EscrowRuntimeState(status: $0.status, quoteCommitment: $0.quoteCommitment,
                                   fundedAtomicAmount: $0.fundedAtomicAmount,
                                   settledAtomicAmount: $0.settledAtomicAmount,
                                   receiptCommitment: $0.receiptCommitment)
            } : nil

            if testCase.expectDecodeError == true {
                XCTAssertThrowsError(try EscrowProjection.funding(runtime),
                                     "case \(testCase.name) must reject a malformed amount")
                continue
            }

            let funding = try EscrowProjection.funding(runtime)
            let settlement = try EscrowProjection.settlement(runtime)
            let wantFunding = try XCTUnwrap(testCase.fundingView)
            let wantSettlement = try XCTUnwrap(testCase.settlementView)

            XCTAssertEqual(funding.found, wantFunding.found, testCase.name)
            XCTAssertEqual(funding.awaitingFunding, wantFunding.awaitingFunding, testCase.name)
            XCTAssertEqual(funding.fundedAtomic, try parseAtomicAmount(wantFunding.fundedAtomic), testCase.name)
            XCTAssertEqual(funding.settledAtomic, try parseAtomicAmount(wantFunding.settledAtomic), testCase.name)
            XCTAssertEqual(funding.receiptCommitment, wantFunding.receiptCommitment, testCase.name)

            XCTAssertEqual(settlement.released, wantSettlement.released, testCase.name)
            XCTAssertEqual(settlement.refunded, wantSettlement.refunded, testCase.name)
            XCTAssertEqual(settlement.providerCreditAtomic,
                           try parseAtomicAmount(wantSettlement.providerCreditAtomic), testCase.name)
        }
    }

    func testGatewaySuccessIsNeverPayment() throws {
        // A funded escrow is NOT a released one: only release-pending means paid.
        let funded = EscrowRuntimeState(status: EscrowStatus.funded.rawValue,
                                        quoteCommitment: "tvm-cell-sha256:aa",
                                        fundedAtomicAmount: "25000000",
                                        settledAtomicAmount: "0", receiptCommitment: "")
        XCTAssertFalse(try EscrowProjection.settlement(funded).released)
        XCTAssertTrue(try EscrowProjection.isExactlyFunded(funded, quotedAtomic: 25_000_000))
        XCTAssertFalse(try EscrowProjection.isExactlyFunded(funded, quotedAtomic: 24_999_999))
    }

    func testOverflowAmountIsRejected() {
        XCTAssertThrowsError(try parseAtomicAmount("18446744073709551616"))
    }
}
