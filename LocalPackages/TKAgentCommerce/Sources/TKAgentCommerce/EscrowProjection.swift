import Foundation

/// EscrowStatus is the finalized escrow runtime status. The values match the
/// canonical escrow decoder; the buyer never invents a status the chain does not
/// define.
public enum EscrowStatus: UInt8, Sendable {
    case awaitingFunding = 0
    case funded = 1
    case releasePending = 2
    case refundPending = 3
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

/// EscrowRuntimeState is the finalized escrow state as decoded from typed chain
/// state. `nil` represents a not-found escrow.
public struct EscrowRuntimeState: Sendable, Equatable {
    public let status: UInt8
    public let quoteCommitment: String
    public let fundedAtomicAmount: String
    public let settledAtomicAmount: String
    public let receiptCommitment: String

    public init(status: UInt8, quoteCommitment: String, fundedAtomicAmount: String,
                settledAtomicAmount: String, receiptCommitment: String) {
        self.status = status
        self.quoteCommitment = quoteCommitment
        self.fundedAtomicAmount = fundedAtomicAmount
        self.settledAtomicAmount = settledAtomicAmount
        self.receiptCommitment = receiptCommitment
    }
}

/// FundingView is the buyer's funding projection of finalized escrow state.
public struct FundingView: Sendable, Equatable {
    public let found: Bool
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
/// single finalized escrow read, mirroring the canonical resolver. Funding and
/// settlement are two projections of the same authoritative status, so they can
/// never disagree.
public enum EscrowProjection {

    /// funding projects the funding view. A not-found escrow reads as
    /// unfunded/awaiting, never funded.
    public static func funding(_ escrow: EscrowRuntimeState?) throws -> FundingView {
        guard let escrow else {
            return FundingView(found: false, awaitingFunding: true, fundedAtomic: 0,
                               settledAtomic: 0, receiptCommitment: "")
        }
        let funded = try parseAtomicAmount(escrow.fundedAtomicAmount)
        let settled = try parseAtomicAmount(escrow.settledAtomicAmount)
        return FundingView(
            found: true,
            awaitingFunding: escrow.status == EscrowStatus.awaitingFunding.rawValue,
            fundedAtomic: funded,
            settledAtomic: settled,
            receiptCommitment: escrow.receiptCommitment
        )
    }

    /// settlement projects the settlement view. Release and refund are the
    /// mutually exclusive terminal outcomes; only a release credits the provider.
    public static func settlement(_ escrow: EscrowRuntimeState?) throws -> SettlementView {
        guard let escrow else {
            return SettlementView(released: false, refunded: false, providerCreditAtomic: 0)
        }
        let settled = try parseAtomicAmount(escrow.settledAtomicAmount)
        let released = escrow.status == EscrowStatus.releasePending.rawValue
        return SettlementView(
            released: released,
            refunded: escrow.status == EscrowStatus.refundPending.rawValue,
            providerCreditAtomic: released ? settled : 0
        )
    }

    /// isExactlyFunded reports whether the escrow holds exactly the quoted amount
    /// in finalized state — the only condition under which a buyer may treat a
    /// funded escrow as safe to dispatch against.
    public static func isExactlyFunded(_ escrow: EscrowRuntimeState?, quotedAtomic: UInt64) throws -> Bool {
        let view = try funding(escrow)
        return view.found && view.fundedAtomic == quotedAtomic
    }
}
