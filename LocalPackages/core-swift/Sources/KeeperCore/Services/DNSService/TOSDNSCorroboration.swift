import Foundation

/// Cross-endpoint corroboration for `.tos` resolution (W1 mitigation).
///
/// `TOSDNSResolver` reads the real on-chain Domain contracts, but through a single JSON-RPC node
/// whose answers it cannot cryptographically verify (the node surface does not yet expose Merkle
/// proofs). A malicious, compromised, or MITM'd node can therefore forge a `.tos -> address`
/// mapping and misdirect a payment. Corroboration runs the SAME resolution through two or more
/// INDEPENDENT nodes and accepts it only if every node agrees on the resolved address and resolver
/// path. It raises the bar from "one lying endpoint is enough" to "every configured endpoint must
/// collude (or all be MITM'd) and the resolver paths must match." It is defense-in-depth, not a
/// replacement for proof verification, which remains blocked on the node exposing account-state
/// proofs.
enum TOSDNSCorroboration {
    /// Return the evidence only if every result agrees on the resolved address, canonical name, and
    /// resolver path. Masterchain checkpoints are per-node (each node selects its own finalized
    /// block) and are intentionally NOT compared. Requires >= 2 independent results; fails closed
    /// otherwise.
    static func corroborate(_ results: [TOSDNSResolutionEvidence]) throws -> TOSDNSResolutionEvidence {
        guard results.count >= 2, let primary = results.first else {
            throw TOSDNSError.invalidResponse("cross-endpoint corroboration requires >= 2 independent results")
        }
        for other in results.dropFirst() {
            guard other.resolvedAddress == primary.resolvedAddress else {
                throw TOSDNSError.invalidResponse(
                    "DNS resolution disagreement across endpoints: \(primary.resolvedAddress) vs \(other.resolvedAddress)"
                )
            }
            guard other.canonicalName == primary.canonicalName else {
                throw TOSDNSError.invalidResponse("DNS canonical-name disagreement across endpoints")
            }
            guard other.resolverPath == primary.resolverPath else {
                throw TOSDNSError.invalidResponse("DNS resolver-path disagreement across endpoints")
            }
        }
        return primary
    }
}

extension API {
    /// W1: resolve `.tos` through this endpoint AND every independent endpoint in `corroborators`,
    /// returning the evidence only if all agree (see `TOSDNSCorroboration`). Use this on payment
    /// paths so a single malicious/compromised/MITM'd endpoint cannot forge the destination address.
    /// With no corroborators this degrades to the single-endpoint `resolveTOSDomain`; callers on
    /// security-sensitive paths should treat the absence of corroborators as reduced assurance.
    ///
    /// The corroborating `API` instances MUST target independent operators for this to mean anything.
    func resolveTOSDomainCorroborated(_ name: String, corroborators: [API]) async throws -> TOSDNSResolutionEvidence {
        let primary = try await resolveTOSDomain(name)
        guard !corroborators.isEmpty else { return primary }
        var results = [primary]
        for endpoint in corroborators {
            results.append(try await endpoint.resolveTOSDomain(name))
        }
        return try TOSDNSCorroboration.corroborate(results)
    }
}
