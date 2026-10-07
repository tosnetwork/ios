import XCTest
@testable import CoreComponents
final class TOSV5R2ProofBridgeTests: XCTestCase {
    func testRealHistoricalProofAndMissingMaterialRefusal() throws {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "v5r2-proof", withExtension: nil))
        func bytes(_ path: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(path)) }
        let anchor = try bytes("anchor.json"), request = try bytes("historical-request.json")
        let material = try [(2, "chain-0000.tl"), (4, "config.tl"), (5, "account.tl"), (6, "exec-config.tl")].map { kind, name in
            TOSV5R2ProofBridge.Material(kind: UInt32(kind), bytes: try bytes("historical/" + name))
        }
        let result = try TOSV5R2ProofBridge.verify(anchor: anchor, request: request, state: Data(), now: 1791200932, material: material)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.verified) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "verified")
        XCTAssertTrue(result.nextState.isEmpty)
        XCTAssertThrowsError(try TOSV5R2ProofBridge.verify(anchor: anchor, request: request, state: Data(), now: 1791200932, material: []))
    }
}
