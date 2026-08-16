import Foundation

public struct FinalizedObservation: Sendable, Equatable {
    public let endpoint: String
    public let network: NetworkTuple
    public let blockRoot: String
    public let stateDigest: String
    public let finalized: Bool

    public init(endpoint: String, network: NetworkTuple, blockRoot: String,
                stateDigest: String, finalized: Bool) {
        self.endpoint = endpoint
        self.network = network
        self.blockRoot = blockRoot
        self.stateDigest = stateDigest
        self.finalized = finalized
    }
}

public enum FinalityDecision: Sendable, Equatable {
    case invalidConfiguration
    case pending
    case finalized(blockRoot: String, stateDigest: String, votes: Int)
}

/// Counts only distinct configured endpoints that attest the exact same
/// finalized block and state on the expected network. Duplicate or conflicting
/// replies from one endpoint never create additional votes.
public enum FinalityQuorum {
    public static func decide(configuredEndpoints: [String], expectedNetwork: NetworkTuple,
                              observations: [FinalizedObservation], quorum: Int = 2) -> FinalityDecision {
        guard configuredEndpoints.count == 3, Set(configuredEndpoints).count == 3,
              configuredEndpoints.allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              quorum >= 2, quorum <= configuredEndpoints.count else {
            return .invalidConfiguration
        }

        let configured = Set(configuredEndpoints)
        let byEndpoint = Dictionary(grouping: observations.filter { configured.contains($0.endpoint) },
                                    by: \.endpoint)
        var votes: [String: (root: String, digest: String, count: Int)] = [:]
        for values in byEndpoint.values where values.count == 1 {
            let value = values[0]
            guard value.finalized, value.network == expectedNetwork,
                  !value.blockRoot.isEmpty, !value.stateDigest.isEmpty else { continue }
            let key = value.blockRoot + "\u{0}" + value.stateDigest
            let previous = votes[key]
            votes[key] = (value.blockRoot, value.stateDigest, (previous?.count ?? 0) + 1)
        }
        guard let winner = votes.values.first(where: { $0.count >= quorum }) else { return .pending }
        return .finalized(blockRoot: winner.root, stateDigest: winner.digest, votes: winner.count)
    }
}
