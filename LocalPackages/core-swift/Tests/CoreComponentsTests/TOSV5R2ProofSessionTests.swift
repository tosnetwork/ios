import XCTest
@testable import CoreComponents
final class TOSV5R2ProofSessionTests: XCTestCase {
    func testPrivateExcludedCheckpointEnrollReopenAndLostState() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "v5r2-proof", withExtension: nil))
        func bytes(_ name: String) throws -> Data { try Data(contentsOf: fixture.appendingPathComponent(name)) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID(), anchor = try bytes("anchor.json"), request = try bytes("live-request.json")
        func material(_ chain: String) throws -> [TOSV5R2ProofBridge.Material] {
            try [(1, "live/masterchain-info.tl"), (4, "live/config.tl"), (2, chain)].map { kind, path in
                TOSV5R2ProofBridge.Material(kind: UInt32(kind), bytes: try bytes(path))
            }
        }
        let initial = try material("historical/chain-0000.tl"), current = try material("live/chain-0000.tl")
        let session = try TOSV5R2ProofSession(walletID: id, locallyProvisionedAnchor: anchor, baseDirectory: base)
        XCTAssertThrowsError(try session.read(request: request, now: 1791200932, material: initial))
        let result = try session.enroll(request: request, now: 1791200932, material: initial)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "verified")
        let directory = base.appendingPathComponent("v5r2-proof-checkpoints/" + id.uuidString)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let state = directory.appendingPathComponent("checkpoint.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
        let reopened = try TOSV5R2ProofSession(walletID: id, locallyProvisionedAnchor: anchor, baseDirectory: base)
        XCTAssertFalse(try reopened.read(request: request, now: 1791200932, material: current).isEmpty)
        try FileManager.default.removeItem(at: state)
        XCTAssertThrowsError(try reopened.enroll(request: request, now: 1791200932, material: initial))
    }
}
