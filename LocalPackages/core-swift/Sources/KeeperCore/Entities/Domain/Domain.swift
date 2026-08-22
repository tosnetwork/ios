import Foundation
import TonSwift

public struct Domain: Equatable {
    public let domain: String
    public let friendlyAddress: FriendlyAddress
    public let evidence: TOSDNSResolutionEvidence?

    public init(
        domain: String,
        friendlyAddress: FriendlyAddress,
        evidence: TOSDNSResolutionEvidence? = nil
    ) {
        self.domain = domain
        self.friendlyAddress = friendlyAddress
        self.evidence = evidence
    }
}
