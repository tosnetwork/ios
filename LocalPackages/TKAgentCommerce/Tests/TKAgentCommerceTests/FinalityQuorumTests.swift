import XCTest
@testable import TKAgentCommerce

final class FinalityQuorumTests: XCTestCase {
    private let network = NetworkTuple(networkID: "local", genesisRoot: "root", genesisFile: "file")
    private let endpoints = ["http://node1", "http://node2", "http://node3"]

    func testRequiresTwoDistinctMatchingFinalizedNodes() {
        let observations = [
            FinalizedObservation(endpoint: endpoints[0], network: network, blockRoot: "b1", stateDigest: "s1", finalized: true),
            FinalizedObservation(endpoint: endpoints[1], network: network, blockRoot: "b1", stateDigest: "s1", finalized: true),
            FinalizedObservation(endpoint: endpoints[2], network: network, blockRoot: "b2", stateDigest: "s2", finalized: true),
        ]
        XCTAssertEqual(FinalityQuorum.decide(configuredEndpoints: endpoints, expectedNetwork: network,
                                             observations: observations),
                       .finalized(blockRoot: "b1", stateDigest: "s1", votes: 2))
    }

    func testDuplicateWrongNetworkAndUnfinalizedRepliesDoNotCount() {
        let other = NetworkTuple(networkID: "other", genesisRoot: "root", genesisFile: "file")
        let duplicate = [
            FinalizedObservation(endpoint: endpoints[0], network: network, blockRoot: "b1", stateDigest: "s1", finalized: true),
            FinalizedObservation(endpoint: endpoints[0], network: network, blockRoot: "b1", stateDigest: "s1", finalized: true),
            FinalizedObservation(endpoint: endpoints[1], network: other, blockRoot: "b1", stateDigest: "s1", finalized: true),
            FinalizedObservation(endpoint: endpoints[2], network: network, blockRoot: "b1", stateDigest: "s1", finalized: false),
        ]
        XCTAssertEqual(FinalityQuorum.decide(configuredEndpoints: endpoints, expectedNetwork: network,
                                             observations: duplicate), .pending)
        XCTAssertEqual(FinalityQuorum.decide(configuredEndpoints: [endpoints[0], endpoints[0], endpoints[2]],
                                             expectedNetwork: network, observations: []), .invalidConfiguration)
    }
}
