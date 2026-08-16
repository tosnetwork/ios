import Foundation

public protocol FundingSubmitter {
    /// Broadcasts one funding attempt only after the caller has durably acquired
    /// fundingLeaseID. An error is ambiguous: the coordinator never calls this
    /// method again for the same purchase and switches to read-only resolution.
    func submitFunding(purchaseID: String, fundingLeaseID: String) throws
}

public struct FundingObservation: Sendable, Equatable {
    public let endpoint: String
    public let network: NetworkTuple
    public let blockRoot: String
    public let stateDigest: String
    public let finalized: Bool
    public let fundedAtomic: String

    public init(endpoint: String, network: NetworkTuple, blockRoot: String,
                stateDigest: String, finalized: Bool, fundedAtomic: String) {
        self.endpoint = endpoint
        self.network = network
        self.blockRoot = blockRoot
        self.stateDigest = stateDigest
        self.finalized = finalized
        self.fundedAtomic = fundedAtomic
    }
}

public protocol FundingFinalityResolver {
    /// Returns one current finalized-state observation per configured endpoint.
    /// Transport success alone is not a funding observation.
    func resolveFunding(purchaseID: String) throws -> [FundingObservation]
}

public enum FundingSubmissionResult: Sendable, Equatable {
    case submitted(fundingLeaseID: String)
    case reconcileOnly(fundingLeaseID: String)
}

public enum FundingReconciliationResult: Sendable, Equatable {
    case pending
    case funded(blockRoot: String, stateDigest: String, votes: Int)
    case alreadyBeyondFunding(phase: String)
}

public enum PurchaseCoordinatorError: Error, Equatable {
    case invalidPhase
    case invalidExpectedAmount
    case invalidFinalityConfiguration
}

/// Joins the durable funding lease to finalized multi-endpoint resolution. It
/// is deliberately small: platform networking and signing are injected, while
/// the safety decision about whether they may run remains inside this module.
public final class PurchaseCoordinator {
    private let journal: PurchaseJournal

    public init(journal: PurchaseJournal) {
        self.journal = journal
    }

    /// Acquires and persists the only funding lease before invoking the platform
    /// submitter. Every later call is reconciliation-only, including after an
    /// ambiguous submit error or process restart.
    public func submitFunding(
        fundingLeaseID: String,
        nowUnix: UInt64,
        submitter: FundingSubmitter
    ) throws -> FundingSubmissionResult {
        let current = try journal.load()
        if current.phase == "prepared" {
            let leased: PurchaseJournalRecord
            do {
                leased = try journal.acquireFundingLease(id: fundingLeaseID, nowUnix: nowUnix)
            } catch PurchaseJournalError.fundingLeaseUnavailable {
                return try reconciliationOnlyResult()
            }
            try submitter.submitFunding(
                purchaseID: leased.purchaseID,
                fundingLeaseID: leased.fundingLeaseID!
            )
            return .submitted(fundingLeaseID: leased.fundingLeaseID!)
        }
        guard PurchasePhase.order(current.phase) >= PurchasePhase.order("funding_lease") else {
            throw PurchaseCoordinatorError.invalidPhase
        }
        return try reconciliationOnlyResult()
    }

    /// Performs one polling step. Funding becomes authoritative only when two
    /// distinct configured endpoints agree on the same finalized block/state
    /// and the decoded escrow amount exactly equals expectedAtomic.
    public func pollFunding(
        configuredEndpoints: [String],
        expectedNetwork: NetworkTuple,
        expectedAtomic: String,
        nowUnix: UInt64,
        resolver: FundingFinalityResolver
    ) throws -> FundingReconciliationResult {
        let current = try journal.load()
        if PurchasePhase.order(current.phase) >= PurchasePhase.order("funded") {
            return .alreadyBeyondFunding(phase: current.phase)
        }
        guard current.phase == "funding_lease" else {
            throw PurchaseCoordinatorError.invalidPhase
        }
        guard let expected = try? parseAtomicAmount(expectedAtomic), expected > 0 else {
            throw PurchaseCoordinatorError.invalidExpectedAmount
        }
        let observations = try resolver.resolveFunding(purchaseID: current.purchaseID)
        let decision = FinalityQuorum.decide(
            configuredEndpoints: configuredEndpoints,
            expectedNetwork: expectedNetwork,
            observations: observations.map { observation in
                let amountMatches = (try? parseAtomicAmount(observation.fundedAtomic)) == expected
                return FinalizedObservation(
                    endpoint: observation.endpoint,
                    network: observation.network,
                    blockRoot: observation.blockRoot,
                    stateDigest: observation.stateDigest,
                    finalized: observation.finalized && amountMatches
                )
            }
        )
        switch decision {
        case .invalidConfiguration:
            throw PurchaseCoordinatorError.invalidFinalityConfiguration
        case .pending:
            return .pending
        case let .finalized(blockRoot, stateDigest, votes):
            do {
                _ = try journal.advance(to: "funded", nowUnix: nowUnix)
            } catch PurchaseJournalError.illegalTransition {
                let raced = try journal.load()
                guard PurchasePhase.order(raced.phase) >= PurchasePhase.order("funded") else {
                    throw PurchaseJournalError.illegalTransition
                }
            }
            return .funded(blockRoot: blockRoot, stateDigest: stateDigest, votes: votes)
        }
    }

    private func reconciliationOnlyResult() throws -> FundingSubmissionResult {
        let current = try journal.load()
        guard PurchasePhase.order(current.phase) >= PurchasePhase.order("funding_lease"),
              let fundingLeaseID = current.fundingLeaseID else {
            throw PurchaseCoordinatorError.invalidPhase
        }
        return .reconcileOnly(fundingLeaseID: fundingLeaseID)
    }
}
