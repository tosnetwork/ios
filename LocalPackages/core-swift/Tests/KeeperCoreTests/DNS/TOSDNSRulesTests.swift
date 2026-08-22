import BigInt
import Foundation
@testable import KeeperCore
import XCTest

final class TOSDNSRulesTests: XCTestCase {
    private struct TIP1Corpus: Decodable {
        struct Category: Decodable { let sha256: String }
        struct NameVector: Decodable {
            let input: String
            let encodedHex: String?
            let result: String

            enum CodingKeys: String, CodingKey {
                case input, result
                case encodedHex = "encoded_hex"
            }
        }
        struct Lifecycle: Decodable { let renewalIntervalSeconds: UInt64
            enum CodingKeys: String, CodingKey { case renewalIntervalSeconds = "renewal_interval_seconds" }
        }
        struct ResolverPolicy: Decodable { let maximumContacts: Int
            enum CodingKeys: String, CodingKey { case maximumContacts = "maximum_contacts" }
        }

        let schema: String
        let categories: [String: Category]
        let nameEncoding: [NameVector]
        let lifecycle: Lifecycle
        let resolverPolicy: ResolverPolicy

        enum CodingKeys: String, CodingKey {
            case schema, categories, lifecycle
            case nameEncoding = "name_encoding"
            case resolverPolicy = "resolver_policy"
        }
    }

    func testConsumesCanonicalTIP1CorpusWithoutSemanticCopies() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tip-1-dns-v1", withExtension: "json"))
        let corpus = try JSONDecoder().decode(TIP1Corpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(corpus.schema, "tos.tip-1.dns-v1.v1")
        XCTAssertEqual(corpus.lifecycle.renewalIntervalSeconds, 31_622_400)
        XCTAssertEqual(corpus.resolverPolicy.maximumContacts, TOSDNSRules.maximumContacts)
        XCTAssertEqual(corpus.categories["wallet"]?.sha256, String(BigUInt(TOSDNSRules.walletCategory)!, radix: 16))
        for vector in corpus.nameEncoding where vector.result == "accept" {
            let encoded = TOSDNSRules.encode(try TOSDNSRules.canonicalName(vector.input))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(encoded, vector.encodedHex)
        }
    }

    func testConsumesTIP1NameEncodingVectors() throws {
        let canonical = try TOSDNSRules.canonicalName("translate.alice.tos")
        XCTAssertEqual(canonical, "translate.alice.tos")
        XCTAssertEqual(
            TOSDNSRules.encode(canonical).map { String(format: "%02x", $0) }.joined(),
            "746f7300616c696365007472616e736c61746500"
        )
    }

    func testRejectsNonCanonicalRegistrationSpellings() {
        XCTAssertEqual(try? TOSDNSRules.canonicalName("Alice.tos"), "alice.tos")
        XCTAssertThrowsError(try TOSDNSRules.canonicalName("alice.tos."))
        XCTAssertThrowsError(try TOSDNSRules.canonicalName("alice..tos"))
        XCTAssertThrowsError(try TOSDNSRules.canonicalName("alice.ton"))
        XCTAssertThrowsError(try TOSDNSRules.canonicalName("älice.tos"))
    }

    func testAcceptsOnlyComponentBoundaries() throws {
        let query = TOSDNSRules.encode(try TOSDNSRules.canonicalName("alice.tos"))
        XCTAssertTrue(TOSDNSRules.isComponentBoundary(consumedBytes: 3, query: query))
        XCTAssertTrue(TOSDNSRules.isComponentBoundary(consumedBytes: 4, query: query))
        XCTAssertTrue(TOSDNSRules.isComponentBoundary(consumedBytes: query.count, query: query))
        XCTAssertFalse(TOSDNSRules.isComponentBoundary(consumedBytes: 2, query: query))
    }

    func testLeaseBoundaryMatchesTIP1Exactly() throws {
        XCTAssertEqual(
            try TOSDNSRules.renewalDeadline(lastFillUpTime: 1_000, blockTime: 31_623_400),
            31_623_400
        )
        XCTAssertThrowsError(
            try TOSDNSRules.renewalDeadline(lastFillUpTime: 1_000, blockTime: 31_623_401)
        ) { error in
            XCTAssertEqual(error as? TOSDNSError, .unsafeLifecycle)
        }
    }

    func testPinsTIP1WalletCategoryAndHopBudget() {
        XCTAssertEqual(TOSDNSRules.maximumContacts, 8)
        XCTAssertEqual(
            TOSDNSRules.walletCategory,
            "105311596331855300602201538317979276640056460191511695660591596829410056223515"
        )
    }

    func testRejectsStaleOrFutureCheckpointTime() throws {
        try TOSDNSRules.validateCheckpointTime(1_000, now: 1_120)
        XCTAssertThrowsError(try TOSDNSRules.validateCheckpointTime(1_000, now: 1_121))
        XCTAssertThrowsError(try TOSDNSRules.validateCheckpointTime(1_121, now: 1_000))
    }
}
