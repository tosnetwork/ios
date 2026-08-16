import XCTest
@testable import TKAgentCommerce

/// Decodes the SAME shared Contact Card vector the Go reference is verified
/// against (its valid case carries a real ed25519 signature over the canonical
/// preimage), so the Swift `contactBytes` is proven byte-identical to the issuer
/// and to the Android client, and the stateless gate matches exactly.
final class ContactCardTests: XCTestCase {

    private struct Vectors: Decodable {
        let schema: String
        let nowUnix: UInt64
        let network: Network
        let cases: [Case]
    }
    private struct Network: Decodable {
        let networkId: String
        let genesisRoot: String
        let genesisFile: String
    }
    private struct Case: Decodable {
        let name: String
        let card: Card
        let contactBytesHex: String
        let expect: String
    }
    private struct Card: Decodable {
        let agentId: String
        let networkId: String
        let genesisRoot: String
        let genesisFile: String
        let endpoint: String
        let capabilities: [String]
        let expiresAtUnix: UInt64
        let publicKeyHex: String
        let signatureHex: String
    }

    private func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    private func bytesToHex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    func testContactCardMatchesSharedVectors() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "mobile_buyer_contact_card_v1", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let vectors = try decoder.decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertEqual(vectors.schema, "tos.service.mobile-buyer-contact-card.v1")

        let network = NetworkTuple(networkID: vectors.network.networkId,
                                   genesisRoot: vectors.network.genesisRoot,
                                   genesisFile: vectors.network.genesisFile)

        for testCase in vectors.cases {
            let facts = ContactCardFacts(
                agentID: testCase.card.agentId, networkID: testCase.card.networkId,
                genesisRoot: testCase.card.genesisRoot, genesisFile: testCase.card.genesisFile,
                endpoint: testCase.card.endpoint, capabilities: testCase.card.capabilities,
                expiresAtUnix: testCase.card.expiresAtUnix,
                publicKey: hexToBytes(testCase.card.publicKeyHex),
                signature: hexToBytes(testCase.card.signatureHex))

            XCTAssertEqual(bytesToHex(ContactCard.contactBytes(facts)), testCase.contactBytesHex,
                           "contactBytes mismatch for \(testCase.name)")
            XCTAssertEqual(ContactCard.validateStateless(facts, network: network, nowUnix: vectors.nowUnix).rawValue,
                           testCase.expect, testCase.name)
            if testCase.expect == ContactReason.ok.rawValue {
                XCTAssertTrue(ContactCard.verifySignature(facts), testCase.name)
                let tampered = ContactCardFacts(
                    agentID: facts.agentID, networkID: facts.networkID,
                    genesisRoot: facts.genesisRoot, genesisFile: facts.genesisFile,
                    endpoint: facts.endpoint + "/tampered", capabilities: facts.capabilities,
                    expiresAtUnix: facts.expiresAtUnix, publicKey: facts.publicKey,
                    signature: facts.signature)
                XCTAssertFalse(ContactCard.verifySignature(tampered), testCase.name)
            }
        }
    }
}
