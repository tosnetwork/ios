import Foundation
import XCTest
@testable import TKAgentCommerce

final class PurchaseCoordinatorTests: XCTestCase {
    func testFundingSubmitterRunsOnceAcrossRestart() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try preparedJournal(directory: directory)
        let submitter = RecordingSubmitter()

        let first = try PurchaseCoordinator(journal: journal).submitFunding(
            fundingLeaseID: "lease-1", nowUnix: 3, submitter: submitter
        )
        let restarted = try PurchaseCoordinator(journal: PurchaseJournal(directory: directory)).submitFunding(
            fundingLeaseID: "lease-2", nowUnix: 4, submitter: submitter
        )

        XCTAssertEqual(first, .submitted(fundingLeaseID: "lease-1"))
        XCTAssertEqual(restarted, .reconcileOnly(fundingLeaseID: "lease-1"))
        XCTAssertEqual(submitter.calls, 1)
    }

    func testAmbiguousSubmissionNeverRunsAgain() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try preparedJournal(directory: directory)
        let submitter = RecordingSubmitter(throwsAfterCall: true)
        XCTAssertThrowsError(try PurchaseCoordinator(journal: journal).submitFunding(
            fundingLeaseID: "lease-ambiguous", nowUnix: 3, submitter: submitter
        ))

        let restarted = try PurchaseCoordinator(journal: PurchaseJournal(directory: directory)).submitFunding(
            fundingLeaseID: "ignored", nowUnix: 4, submitter: submitter
        )
        XCTAssertEqual(restarted, .reconcileOnly(fundingLeaseID: "lease-ambiguous"))
        XCTAssertEqual(submitter.calls, 1)
    }

    func testFundingRequiresExactTwoOfThreeFinalizedAgreement() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try preparedJournal(directory: directory)
        _ = try journal.acquireFundingLease(id: "lease-finality", nowUnix: 3)
        let network = NetworkTuple(networkID: "tos-local", genesisRoot: "root", genesisFile: "file")
        let endpoints = ["https://one", "https://two", "https://three"]
        let resolver = StaticFundingResolver(observations: [
            FundingObservation(endpoint: endpoints[0], network: network, blockRoot: "block", stateDigest: "state", finalized: true, fundedAtomic: "25000000"),
            FundingObservation(endpoint: endpoints[1], network: network, blockRoot: "block", stateDigest: "state", finalized: true, fundedAtomic: "25000000"),
            FundingObservation(endpoint: endpoints[2], network: network, blockRoot: "other", stateDigest: "other", finalized: true, fundedAtomic: "1"),
        ])

        let result = try PurchaseCoordinator(journal: journal).pollFunding(
            configuredEndpoints: endpoints, expectedNetwork: network,
            expectedAtomic: "25000000", nowUnix: 4, resolver: resolver
        )

        XCTAssertEqual(result, .funded(blockRoot: "block", stateDigest: "state", votes: 2))
        XCTAssertEqual(try journal.load().phase, "funded")
        XCTAssertEqual(resolver.calls, 1)
    }

    func testWrongAmountAndEndpointEquivocationStayPending() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try preparedJournal(directory: directory)
        _ = try journal.acquireFundingLease(id: "lease-pending", nowUnix: 3)
        let network = NetworkTuple(networkID: "tos-local", genesisRoot: "root", genesisFile: "file")
        let endpoints = ["https://one", "https://two", "https://three"]
        let resolver = StaticFundingResolver(observations: [
            FundingObservation(endpoint: endpoints[0], network: network, blockRoot: "block", stateDigest: "state", finalized: true, fundedAtomic: "25000000"),
            FundingObservation(endpoint: endpoints[0], network: network, blockRoot: "other", stateDigest: "other", finalized: true, fundedAtomic: "25000000"),
            FundingObservation(endpoint: endpoints[1], network: network, blockRoot: "block", stateDigest: "state", finalized: true, fundedAtomic: "24999999"),
        ])

        XCTAssertEqual(try PurchaseCoordinator(journal: journal).pollFunding(
            configuredEndpoints: endpoints, expectedNetwork: network,
            expectedAtomic: "25000000", nowUnix: 4, resolver: resolver
        ), .pending)
        XCTAssertEqual(try journal.load().phase, "funding_lease")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func preparedJournal(directory: URL) throws -> PurchaseJournal {
        let journal = try PurchaseJournal(directory: directory)
        _ = try journal.create(purchaseID: "purchase-1", nowUnix: 1)
        _ = try journal.advance(to: "prepared", nowUnix: 2)
        return journal
    }
}

private enum SubmissionFailure: Error { case ambiguous }

private final class RecordingSubmitter: FundingSubmitter {
    private(set) var calls = 0
    private let throwsAfterCall: Bool

    init(throwsAfterCall: Bool = false) { self.throwsAfterCall = throwsAfterCall }

    func submitFunding(purchaseID: String, fundingLeaseID: String) throws {
        calls += 1
        if throwsAfterCall { throw SubmissionFailure.ambiguous }
    }
}

private final class StaticFundingResolver: FundingFinalityResolver {
    private(set) var calls = 0
    let observations: [FundingObservation]

    init(observations: [FundingObservation]) { self.observations = observations }

    func resolveFunding(purchaseID: String) throws -> [FundingObservation] {
        calls += 1
        return observations
    }
}
