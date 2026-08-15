import Foundation

/// ReviewReason is the verdict of reviewing a Quote before approval. `.ok` means
/// safe to display; every other value is a specific, deterministic rejection, so
/// a malformed Quote is rejected for the same reason on every platform. The raw
/// values match the shared vectors and the Go reference.
public enum ReviewReason: String, Sendable {
    case ok
    case capabilityVersionMissing = "capability_version_missing"
    case manifestDigestMalformed = "manifest_digest_malformed"
    case assetMasterMalformed = "asset_master_malformed"
    case assetWalletCodeHashMalformed = "asset_wallet_code_hash_malformed"
    case amountNotPositive = "amount_not_positive"
    case escrowAddressMalformed = "escrow_address_malformed"
    case quoteCommitmentMalformed = "quote_commitment_malformed"
    case feePayerUnknown = "fee_payer_unknown"
    case expired
}

/// QuoteReview is the set of canonical Accepted Quote facts a buyer must see and
/// validate before approving a spend — exactly what the confirmation screen
/// shows. The buyer approves these commitments, not a ticker or a Gateway claim.
public struct QuoteReview: Sendable, Equatable {
    public let capabilityVersion: String
    public let manifestDigest: String
    public let assetMaster: String
    public let assetWalletCodeHash: String
    public let amountAtomic: String
    public let escrowAddress: String
    public let quoteCommitment: String
    public let feePayer: String
    public let expiryUnix: UInt64

    public init(capabilityVersion: String, manifestDigest: String, assetMaster: String,
                assetWalletCodeHash: String, amountAtomic: String, escrowAddress: String,
                quoteCommitment: String, feePayer: String, expiryUnix: UInt64) {
        self.capabilityVersion = capabilityVersion
        self.manifestDigest = manifestDigest
        self.assetMaster = assetMaster
        self.assetWalletCodeHash = assetWalletCodeHash
        self.amountAtomic = amountAtomic
        self.escrowAddress = escrowAddress
        self.quoteCommitment = quoteCommitment
        self.feePayer = feePayer
        self.expiryUnix = expiryUnix
    }

    /// review validates the Quote facts against the current time. The checks run
    /// in a fixed order so the reason is deterministic. A Gateway response or a
    /// friendly asset ticker never substitutes for a commitment.
    public func review(nowUnix: UInt64) -> ReviewReason {
        if capabilityVersion.isEmpty { return .capabilityVersionMissing }
        if !isShaDigest(manifestDigest) { return .manifestDigestMalformed }
        if !isRawWorkchainZero(assetMaster) { return .assetMasterMalformed }
        if !isCellDigest(assetWalletCodeHash) { return .assetWalletCodeHashMalformed }
        guard let amount = try? parseAtomicAmount(amountAtomic), amount > 0 else { return .amountNotPositive }
        if !isRawWorkchainZero(escrowAddress) { return .escrowAddressMalformed }
        if !isCellDigest(quoteCommitment) { return .quoteCommitmentMalformed }
        if feePayer != "buyer" && feePayer != "provider" { return .feePayerUnknown }
        if expiryUnix <= nowUnix { return .expired }
        return .ok
    }
}

/// isRawWorkchainZero reports whether value is a canonical raw workchain-0
/// address: "0:" followed by 64 lowercase hex characters.
public func isRawWorkchainZero(_ value: String) -> Bool {
    hasPrefixHexBody(value, prefix: "0:")
}

/// isCellDigest reports whether value is a canonical tvm-cell-sha256 digest.
public func isCellDigest(_ value: String) -> Bool {
    hasPrefixHexBody(value, prefix: "tvm-cell-sha256:")
}

/// isShaDigest reports whether value is a canonical sha256 digest.
public func isShaDigest(_ value: String) -> Bool {
    hasPrefixHexBody(value, prefix: "sha256:")
}

private func hasPrefixHexBody(_ value: String, prefix: String) -> Bool {
    guard value.hasPrefix(prefix) else { return false }
    let body = value.dropFirst(prefix.count)
    guard body.count == 64 else { return false }
    return body.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }
}
