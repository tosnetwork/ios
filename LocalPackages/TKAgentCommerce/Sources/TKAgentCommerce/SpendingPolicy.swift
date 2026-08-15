import Foundation

/// PolicyReason is the deterministic verdict of evaluating a Quote against the
/// owner's spending policy. `.ok` means the buyer may proceed automatically;
/// `.manualConfirmation` means it is within policy but needs explicit owner
/// approval; anything else blocks the spend. Raw values match the shared vectors
/// and the Go servicebridge.PolicyEngine.
public enum PolicyReason: String, Sendable {
    case ok
    case policyInvalid = "policy_invalid"
    case policyExpired = "policy_expired"
    case assetNotAllowed = "asset_not_allowed"
    case capabilityNotAllowed = "capability_not_allowed"
    case overPurchaseLimit = "over_purchase_limit"
    case overDailyBudget = "over_daily_budget"
    case manualConfirmation = "manual_confirmation"
}

/// SpendingPolicy is the owner-signed authorization envelope enforced locally
/// before every purchase. Its signature is verified out of band; this type
/// enforces only the bounds.
public struct SpendingPolicy: Sendable, Equatable {
    public let assetMaster: String
    public let assetWalletCodeHash: String
    public let maxAtomicPurchase: UInt64
    public let dailyBudgetAtomic: UInt64
    public let windowSeconds: UInt64
    public let expiryUnix: UInt64
    public let capabilityAllow: Set<String>
    public let confirmationMode: String
    public let hasOwnerSignature: Bool

    public init(assetMaster: String, assetWalletCodeHash: String, maxAtomicPurchase: UInt64,
                dailyBudgetAtomic: UInt64, windowSeconds: UInt64, expiryUnix: UInt64,
                capabilityAllow: Set<String>, confirmationMode: String, hasOwnerSignature: Bool) {
        self.assetMaster = assetMaster
        self.assetWalletCodeHash = assetWalletCodeHash
        self.maxAtomicPurchase = maxAtomicPurchase
        self.dailyBudgetAtomic = dailyBudgetAtomic
        self.windowSeconds = windowSeconds
        self.expiryUnix = expiryUnix
        self.capabilityAllow = capabilityAllow
        self.confirmationMode = confirmationMode
        self.hasOwnerSignature = hasOwnerSignature
    }

    /// isValid mirrors the engine's structural check. Expiry is deliberately not
    /// checked here — it is enforced by the time comparison in `authorize` — so
    /// the reason ordering matches the reference exactly.
    public var isValid: Bool {
        !assetMaster.isEmpty && !assetWalletCodeHash.isEmpty && maxAtomicPurchase > 0 &&
            dailyBudgetAtomic >= maxAtomicPurchase && windowSeconds >= 60 &&
            !capabilityAllow.isEmpty && hasOwnerSignature &&
            (confirmationMode == "auto" || confirmationMode == "manual")
    }
}

/// QuoteFacts is the subset of a Quote the spending policy is evaluated against.
public struct QuoteFacts: Sendable, Equatable {
    public let assetMaster: String
    public let assetWalletCodeHash: String
    public let capabilityID: String
    public let maxAtomicAmount: UInt64

    public init(assetMaster: String, assetWalletCodeHash: String, capabilityID: String, maxAtomicAmount: UInt64) {
        self.assetMaster = assetMaster
        self.assetWalletCodeHash = assetWalletCodeHash
        self.capabilityID = capabilityID
        self.maxAtomicAmount = maxAtomicAmount
    }
}

public enum SpendingPolicyEngine {

    /// authorize evaluates a Quote against the owner policy. Checks run in a
    /// fixed order so the reason is deterministic, and the budget arithmetic is
    /// overflow-safe. spentInWindow is the amount already reserved in the policy
    /// window, counted from the crash-safe journal.
    public static func authorize(_ policy: SpendingPolicy, _ proposal: QuoteFacts,
                                 spentInWindow: UInt64, nowUnix: UInt64) -> PolicyReason {
        if !policy.isValid { return .policyInvalid }
        if nowUnix >= policy.expiryUnix { return .policyExpired }
        if proposal.assetMaster != policy.assetMaster
            || proposal.assetWalletCodeHash != policy.assetWalletCodeHash { return .assetNotAllowed }
        if !policy.capabilityAllow.contains(proposal.capabilityID) { return .capabilityNotAllowed }
        let amount = proposal.maxAtomicAmount
        if amount == 0 || amount > policy.maxAtomicPurchase { return .overPurchaseLimit }
        if spentInWindow > policy.dailyBudgetAtomic
            || amount > policy.dailyBudgetAtomic - spentInWindow { return .overDailyBudget }
        if policy.confirmationMode == "manual" { return .manualConfirmation }
        return .ok
    }
}
