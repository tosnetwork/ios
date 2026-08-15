import Foundation

/// ResumeAction is the crash-recovery decision for a persisted purchase phase.
/// It is the single authority for at-most-once payment across process death:
/// before the funding lease a purchase may still fund; at or after the lease
/// recovery is read-only and NEVER re-pays; once resolved it is complete. Raw
/// values match the shared vectors and the Go reference.
public enum ResumeAction: String, Sendable {
    case invalid
    case mayFund = "may_fund"
    case reconcileNeverRefund = "reconcile_never_refund"
    case complete
}

/// PurchasePhase is the crash-safe purchase-journal phase machine. It mirrors the
/// servicebridge phase functions so a mobile client resumes a purchase after process
/// death with exactly the same safety decision as the buyer engine.
public enum PurchasePhase {

    /// order is the strict forward position of a phase, or -1 if unknown. A
    /// purchase only ever advances forward.
    public static func order(_ phase: String) -> Int {
        switch phase {
        case "intent": return 0
        case "prepared": return 1
        case "funding_lease": return 2
        case "funded": return 3
        case "execution": return 4
        case "receipt": return 5
        case "release": return 6
        case "resolved": return 7
        default: return -1
        }
    }

    /// canAdvance reports whether a purchase may move from one phase to another.
    /// Only strictly-forward transitions between known phases are legal.
    public static func canAdvance(from: String, to: String) -> Bool {
        let fromOrder = order(from)
        let toOrder = order(to)
        return fromOrder >= 0 && toOrder >= 0 && toOrder > fromOrder
    }

    /// canAcquireFundingLease reports whether the single funding lease may be
    /// taken from this phase. Only Prepared may cross into FundingLease.
    public static func canAcquireFundingLease(_ phase: String) -> Bool {
        phase == "prepared"
    }

    /// resumeActionFor decides how to safely resume a purchase after process
    /// death.
    public static func resumeActionFor(_ phase: String) -> ResumeAction {
        let position = order(phase)
        if position < 0 { return .invalid }
        if position < order("funding_lease") { return .mayFund }
        if phase == "resolved" { return .complete }
        return .reconcileNeverRefund
    }
}
