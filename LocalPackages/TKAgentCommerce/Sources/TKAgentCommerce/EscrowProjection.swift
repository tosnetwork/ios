import Foundation

/// EscrowStatus is the status byte of the stablecoin escrow v2 data cell, the
/// only escrow contract the buyer supports. The values are the contract's own
/// `status::` constants; any other byte is refused, never mapped onto a nearby
/// status.
public enum EscrowStatus: UInt8, Sendable {
    /// Deployed, but the buyer has not accepted the Quote. Not fundable.
    case pendingAcceptance = 0
    /// Accepted by the buyer; the escrow takes exactly the quoted amount.
    case awaitingFunding = 1
    /// Holds the quoted amount. Funded is never paid to the provider.
    case funded = 2
    /// A Receipt-bound release to the provider was sent for the full amount.
    case releasePending = 3
    /// A refund of the full amount to the buyer was sent.
    case refundPending = 4
}

/// AtomicAmountError is raised when an atomic amount string is not a canonical
/// unsigned 64-bit value. A malformed amount is rejected, never wrapped into a
/// small balance that could be mistaken for exact funding.
public enum AtomicAmountError: Error, Equatable {
    case notCanonical(String)
}

/// parseAtomicAmount decodes a decimal atomic-amount string. An empty string is
/// zero; anything negative, non-numeric, or larger than UInt64.max is rejected.
public func parseAtomicAmount(_ value: String) throws -> UInt64 {
    if value.isEmpty { return 0 }
    guard let amount = UInt64(value) else {
        throw AtomicAmountError.notCanonical(value)
    }
    return amount
}

/// EscrowStateError is raised when a decoded escrow state is not one the escrow
/// v2 contract can be in. The projection refuses it instead of guessing.
public enum EscrowStateError: Error, Equatable {
    /// The status byte is not an escrow v2 status.
    case unsupportedStatus(UInt8)
    /// The runtime fields contradict what the contract writes in this status.
    case inconsistentState(EscrowStatus)
    /// A commitment is not `tvm-cell-sha256:` followed by 64 lowercase hex digits
    /// (the Receipt commitment may also be empty).
    case malformedCommitment(String)
}

/// EscrowRuntimeState is the finalized escrow v2 state as decoded from the
/// escrow's data cell: the status byte, the Quote commitment, and the runtime
/// cell's funded amount, settled amount, Receipt hash (empty when zero),
/// pending settlement query id and acceptance time. `nil` represents an escrow
/// account that does not exist.
public struct EscrowRuntimeState: Sendable, Equatable {
    public let status: UInt8
    public let quoteCommitment: String
    public let fundedAtomicAmount: String
    public let settledAtomicAmount: String
    public let receiptCommitment: String
    public let acceptedAtUnix: UInt64
    public let pendingQueryID: UInt64

    public init(status: UInt8, quoteCommitment: String, fundedAtomicAmount: String,
                settledAtomicAmount: String, receiptCommitment: String,
                acceptedAtUnix: UInt64, pendingQueryID: UInt64) {
        self.status = status
        self.quoteCommitment = quoteCommitment
        self.fundedAtomicAmount = fundedAtomicAmount
        self.settledAtomicAmount = settledAtomicAmount
        self.receiptCommitment = receiptCommitment
        self.acceptedAtUnix = acceptedAtUnix
        self.pendingQueryID = pendingQueryID
    }
}

/// FundingView is the buyer's funding projection of finalized escrow state.
public struct FundingView: Sendable, Equatable {
    public let found: Bool
    public let pendingAcceptance: Bool
    public let awaitingFunding: Bool
    public let fundedAtomic: UInt64
    public let settledAtomic: UInt64
    public let receiptCommitment: String
}

/// SettlementView is the buyer's settlement projection. `released` is the only
/// signal that means "paid to the provider", and it is derived from finalized
/// escrow status — never from a Gateway response or an HTTP success.
public struct SettlementView: Sendable, Equatable {
    public let released: Bool
    public let refunded: Bool
    public let providerCreditAtomic: UInt64
}

/// EscrowProjection derives the buyer's funding and settlement views from a
/// single finalized escrow v2 read. Funding and settlement are two projections
/// of the same authoritative status, so they can never disagree, and both refuse
/// a state the contract cannot be in.
public enum EscrowProjection {

    private struct Validated {
        let status: EscrowStatus
        let funded: UInt64
        let settled: UInt64
    }

    private static let commitmentPrefix = "tvm-cell-sha256:"

    private static func isCommitment(_ value: String) -> Bool {
        guard value.hasPrefix(commitmentPrefix) else { return false }
        let digest = value.dropFirst(commitmentPrefix.count)
        return digest.count == 64 && digest.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// validate checks the status byte and the per-status runtime invariants the
    /// escrow v2 contract maintains: acceptance time is set exactly once the
    /// Quote is accepted; funds arrive only in funded; a release settles the
    /// full funded amount against a Receipt; a refund settles nothing; and a
    /// pending settlement always names its query id.
    private static func validate(_ escrow: EscrowRuntimeState) throws -> Validated {
        guard let status = EscrowStatus(rawValue: escrow.status) else {
            throw EscrowStateError.unsupportedStatus(escrow.status)
        }
        guard isCommitment(escrow.quoteCommitment) else {
            throw EscrowStateError.malformedCommitment(escrow.quoteCommitment)
        }
        guard escrow.receiptCommitment.isEmpty || isCommitment(escrow.receiptCommitment) else {
            throw EscrowStateError.malformedCommitment(escrow.receiptCommitment)
        }
        let funded = try parseAtomicAmount(escrow.fundedAtomicAmount)
        let settled = try parseAtomicAmount(escrow.settledAtomicAmount)
        let accepted = escrow.acceptedAtUnix > 0
        let hasReceipt = !escrow.receiptCommitment.isEmpty
        let hasQuery = escrow.pendingQueryID != 0
        let consistent: Bool
        switch status {
        case .pendingAcceptance:
            consistent = !accepted && funded == 0 && settled == 0 && !hasReceipt && !hasQuery
        case .awaitingFunding:
            consistent = accepted && funded == 0 && settled == 0 && !hasReceipt && !hasQuery
        case .funded:
            consistent = accepted && funded > 0 && settled == 0 && !hasReceipt && !hasQuery
        case .releasePending:
            consistent = accepted && funded > 0 && settled == funded && hasReceipt && hasQuery
        case .refundPending:
            consistent = accepted && funded > 0 && settled == 0 && !hasReceipt && hasQuery
        }
        guard consistent else {
            throw EscrowStateError.inconsistentState(status)
        }
        return Validated(status: status, funded: funded, settled: settled)
    }

    /// funding projects the funding view. A missing escrow is neither awaiting
    /// funding nor funded: the contract accepts funds only after the buyer has
    /// accepted the Quote on a deployed escrow.
    public static func funding(_ escrow: EscrowRuntimeState?) throws -> FundingView {
        guard let escrow else {
            return FundingView(found: false, pendingAcceptance: false, awaitingFunding: false,
                               fundedAtomic: 0, settledAtomic: 0, receiptCommitment: "")
        }
        let state = try validate(escrow)
        return FundingView(
            found: true,
            pendingAcceptance: state.status == .pendingAcceptance,
            awaitingFunding: state.status == .awaitingFunding,
            fundedAtomic: state.funded,
            settledAtomic: state.settled,
            receiptCommitment: escrow.receiptCommitment
        )
    }

    /// settlement projects the settlement view. Release and refund are mutually
    /// exclusive; only a release credits the provider.
    public static func settlement(_ escrow: EscrowRuntimeState?) throws -> SettlementView {
        guard let escrow else {
            return SettlementView(released: false, refunded: false, providerCreditAtomic: 0)
        }
        let state = try validate(escrow)
        let released = state.status == .releasePending
        return SettlementView(
            released: released,
            refunded: state.status == .refundPending,
            providerCreditAtomic: released ? state.settled : 0
        )
    }

    /// isExactlyFunded reports whether the escrow is in the funded status and
    /// holds exactly the quoted amount in finalized state — the only condition
    /// under which a buyer may treat it as safe to dispatch against. An escrow
    /// whose release or refund is already pending still records the funded
    /// amount, so the amount alone is not enough.
    public static func isExactlyFunded(_ escrow: EscrowRuntimeState?, quotedAtomic: UInt64) throws -> Bool {
        guard let escrow else { return false }
        let state = try validate(escrow)
        return state.status == .funded && quotedAtomic > 0 && state.funded == quotedAtomic
    }
}
