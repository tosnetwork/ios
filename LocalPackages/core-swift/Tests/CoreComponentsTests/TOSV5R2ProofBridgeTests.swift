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
        let bound = try TOSV5R2ProofBridge.verifyHistoricalBound(anchor: anchor, request: request, now: 1791200932, material: material)
        let account = try XCTUnwrap(object["account"] as? [String: Any])
        let codeText = try XCTUnwrap(account["code_hash"] as? String)
        let code = Data(stride(from: 0, to: codeText.count, by: 2).map { offset -> UInt8 in
            let start = codeText.index(codeText.startIndex, offsetBy: offset)
            return UInt8(codeText[start..<codeText.index(start, offsetBy: 2)], radix: 16)!
        })
        XCTAssertFalse(try bound.accountState(expectedAddress: "-1:" + String(repeating: "33", count: 32), expectedCodeHash: code).isEmpty)
        XCTAssertThrowsError(try bound.accountState(expectedAddress: "-1:" + String(repeating: "44", count: 32), expectedCodeHash: code))
        XCTAssertThrowsError(try bound.accountState(expectedAddress: "-1:" + String(repeating: "33", count: 32), expectedCodeHash: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try bound.requireLive(now: 1791200932, maximumAge: 300))
        try bound.requireSameCheckpoint(bound)

        XCTAssertThrowsError(try TOSV5R2ProofBridge.verify(anchor: anchor, request: request, state: Data(), now: 1791200932, material: []))
    }
}
