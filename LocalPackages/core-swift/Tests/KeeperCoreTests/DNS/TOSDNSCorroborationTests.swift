import Foundation
@testable import KeeperCore
import XCTest

final class TOSDNSCorroborationTests: XCTestCase {
    private func evidence(
        address: String,
        path: [String] = ["-1:root", "0:collection", "0:item"],
        name: String = "alice.tos",
        sequence: UInt64 = 100,
        rootHash: String = "aa",
        renewalDeadline: UInt64 = 1_800_000_000
    ) -> TOSDNSResolutionEvidence {
        TOSDNSResolutionEvidence(
            canonicalName: name,
            resolvedAddress: address,
            resolverPath: path,
            masterchainSequence: sequence,
            rootHash: rootHash,
            fileHash: "ff",
            observedAt: 1_700_000_000,
            lastFillUpTime: 1_700_000_000,
            renewalDeadline: renewalDeadline
        )
    }

    private func assertRejected(
        _ results: [TOSDNSResolutionEvidence],
        containing fragment: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try TOSDNSCorroboration.corroborate(results), file: file, line: line) { error in
            guard case let TOSDNSError.invalidResponse(reason) = error else {
                return XCTFail("expected TOSDNSError.invalidResponse, got \(error)", file: file, line: line)
            }
            if let fragment {
                XCTAssertTrue(
                    reason.contains(fragment),
                    "reason \"\(reason)\" does not contain \"\(fragment)\"",
                    file: file,
                    line: line
                )
            }
        }
    }

    func testAgreeingEndpointsReturnSharedEvidenceEvenWithDifferentCheckpoints() throws {
        // Two honest nodes sitting at different finalized blocks still agree on the mapping.
        let a = evidence(address: "0:abc", sequence: 100, rootHash: "aa", renewalDeadline: 1_800_000_000)
        let b = evidence(address: "0:abc", sequence: 103, rootHash: "bb", renewalDeadline: 1_800_000_050)
        let result = try TOSDNSCorroboration.corroborate([a, b])
        XCTAssertEqual(result.resolvedAddress, "0:abc")
        XCTAssertEqual(result, a) // the primary (first) result is the one returned
    }

    func testSingleEndpointForgingDifferentAddressIsRejected() {
        let honest = evidence(address: "0:abc")
        let forged = evidence(address: "0:deadbeef") // a lying or MITM'd node
        assertRejected([honest, forged], containing: "disagreement")
    }

    func testDivergentResolverPathIsRejectedEvenWhenFinalAddressMatches() {
        let honest = evidence(address: "0:abc", path: ["-1:root", "0:collection", "0:item"])
        let rerouted = evidence(address: "0:abc", path: ["-1:root", "0:evil-collection", "0:item"])
        assertRejected([honest, rerouted], containing: "resolver-path")
    }

    func testDivergentCanonicalNameIsRejected() {
        let a = evidence(address: "0:abc", name: "alice.tos")
        let b = evidence(address: "0:abc", name: "bob.tos")
        assertRejected([a, b], containing: "canonical-name")
    }

    func testFewerThanTwoResultsFailsClosed() {
        assertRejected([evidence(address: "0:abc")], containing: ">= 2")
        assertRejected([], containing: ">= 2")
    }

    func testThreeWayAgreementPassesAndSingleDissenterFails() throws {
        let a = evidence(address: "0:abc", sequence: 100, rootHash: "aa")
        let b = evidence(address: "0:abc", sequence: 101, rootHash: "bb")
        let c = evidence(address: "0:abc", sequence: 102, rootHash: "cc")
        XCTAssertEqual(try TOSDNSCorroboration.corroborate([a, b, c]).resolvedAddress, "0:abc")

        let dissenter = evidence(address: "0:evil", sequence: 102, rootHash: "cc")
        assertRejected([a, b, dissenter], containing: "disagreement")
    }
}
