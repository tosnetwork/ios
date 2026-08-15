import XCTest
@testable import TKAgentCommerce

/// Decodes the SAME shared Quote-review vector the Go reference is verified
/// against, so the Swift approval gate is proven identical to the canonical
/// implementation and to the Android client.
final class QuoteReviewTests: XCTestCase {

    private struct Vectors: Decodable {
        let schema: String
        let nowUnix: UInt64
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let review: Fields
        let expect: String
    }

    private struct Fields: Decodable {
        let capabilityVersion: String
        let manifestDigest: String
        let assetMaster: String
        let assetWalletCodeHash: String
        let amountAtomic: String
        let escrowAddress: String
        let quoteCommitment: String
        let feePayer: String
        let expiryUnix: UInt64
    }

    func testReviewMatchesSharedVectors() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "mobile_buyer_quote_review_v1", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let vectors = try decoder.decode(Vectors.self, from: Data(contentsOf: url))

        XCTAssertEqual(vectors.schema, "tos.service.mobile-buyer-quote-review.v1")
        XCTAssertFalse(vectors.cases.isEmpty)

        for testCase in vectors.cases {
            let review = QuoteReview(
                capabilityVersion: testCase.review.capabilityVersion,
                manifestDigest: testCase.review.manifestDigest,
                assetMaster: testCase.review.assetMaster,
                assetWalletCodeHash: testCase.review.assetWalletCodeHash,
                amountAtomic: testCase.review.amountAtomic,
                escrowAddress: testCase.review.escrowAddress,
                quoteCommitment: testCase.review.quoteCommitment,
                feePayer: testCase.review.feePayer,
                expiryUnix: testCase.review.expiryUnix
            )
            XCTAssertEqual(review.review(nowUnix: vectors.nowUnix).rawValue, testCase.expect, testCase.name)
        }
    }

    func testTickerOnlyOrGatewayFeePayerRejected() {
        let base = QuoteReview(
            capabilityVersion: "1.0.0",
            manifestDigest: "sha256:" + String(repeating: "a", count: 64),
            assetMaster: "0:" + String(repeating: "a", count: 64),
            assetWalletCodeHash: "tvm-cell-sha256:" + String(repeating: "a", count: 64),
            amountAtomic: "25000000",
            escrowAddress: "0:" + String(repeating: "b", count: 64),
            quoteCommitment: "tvm-cell-sha256:" + String(repeating: "c", count: 64),
            feePayer: "gateway",
            expiryUnix: 2_000_000_000
        )
        XCTAssertEqual(base.review(nowUnix: 1_786_800_000), .feePayerUnknown)
    }
}
