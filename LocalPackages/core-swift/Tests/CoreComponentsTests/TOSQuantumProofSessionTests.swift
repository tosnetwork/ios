import XCTest
@testable import CoreComponents
final class TOSQuantumProofSessionTests: XCTestCase {
    func testPrivateExcludedCheckpointEnrollReopenAndLostState() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "quantum-proof", withExtension: nil))
        func bytes(_ name: String) throws -> Data { try Data(contentsOf: fixture.appendingPathComponent(name)) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID(), anchor = try bytes("anchor.json"), request = try bytes("live-request.json")
        func material(_ chain: String) throws -> [TOSQuantumProofBridge.Material] {
            try [(1, "live/masterchain-info.tl"), (4, "live/config.tl"), (2, chain)].map { kind, path in
                TOSQuantumProofBridge.Material(kind: UInt32(kind), bytes: try bytes(path))
            }
        }
        let initial = try material("historical/chain-0000.tl"), current = try material("live/chain-0000.tl")
        let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: anchor, baseDirectory: base)
        XCTAssertThrowsError(try session.read(request: request, now: 1791200932, material: initial))
        let result = try session.enroll(request: request, now: 1791200932, material: initial)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "verified")
        let directory = base.appendingPathComponent("quantum-proof-checkpoints/" + id.uuidString)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let state = directory.appendingPathComponent("checkpoint.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
        let reopened = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: anchor, baseDirectory: base)
        XCTAssertFalse(try reopened.read(request: request, now: 1791200932, material: current).isEmpty)
        try FileManager.default.removeItem(at: state)
        XCTAssertThrowsError(try reopened.enroll(request: request, now: 1791200932, material: initial))
    }
    func testAcquisitionCommitsBeforeReturningAndPropagatesTransportFailure() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "quantum-proof", withExtension: nil))
        func bytes(_ path: String) throws -> Data { try Data(contentsOf: fixture.appendingPathComponent(path)) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: bytes("anchor.json"), baseDirectory: base)
        let replies = try ["live/masterchain-info.tl", "historical/chain-0000.tl", "live/config.tl"].map(bytes)
        var queries = 0
        let result = try session.enrollBound(request: bytes("live-request.json"), now: 1791200932) { query, capacity in
            XCTAssertFalse(query.isEmpty)
            guard queries < replies.count else { throw TOSPQError.invalidInput }
            let reply = replies[queries]; queries += 1
            XCTAssertLessThanOrEqual(reply.count, capacity)
            return reply
        }
        XCTAssertEqual(queries, 3)
        try result.requireLive(now: 1791200932, maximumAge: 300)
        try result.requireSameCheckpoint(result)
        XCTAssertFalse(try result.provenConfigParam(34).isEmpty)
        XCTAssertThrowsError(try result.provenConfigParam(48), "Unproven configuration accepted")
        XCTAssertThrowsError(try result.requireLive(now: 1791201932, maximumAge: 300))
        XCTAssertThrowsError(try result.requireLive(now: 1791200931, maximumAge: 300))
        XCTAssertThrowsError(try result.configParam(34, expectedCellHash: Data(repeating: 0, count: 32)))
        let fixed = try result.requestAtCheckpoint(configIndices: [34], maximumAge: 300)
        let fixedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: fixed) as? [String: Any])
        XCTAssertNotNil(fixedObject["target"], "Fixed checkpoint target missing")
        let target = try XCTUnwrap(fixedObject["target"] as? [String: Any])
        XCTAssertEqual(Set(target.keys), Set(["workchain", "shard", "seqno", "root_hash", "file_hash"]))
        let fixedReplies = try ["live/chain-0000.tl", "live/config.tl"].map(bytes)
        var fixedCalls = 0
        let atPoint = try session.readBound(request: fixed, now: 1791200932) { _, capacity in
            guard fixedCalls < fixedReplies.count else { throw TOSPQError.invalidInput }
            let reply = fixedReplies[fixedCalls]; fixedCalls += 1
            XCTAssertLessThanOrEqual(reply.count, capacity)
            return reply
        }
        XCTAssertEqual(fixedCalls, 2)
        try result.requireSameCheckpoint(atPoint)
        try atPoint.requireLive(now: 1791200932, maximumAge: 300)
        let state = base.appendingPathComponent("quantum-proof-checkpoints/" + id.uuidString + "/checkpoint.json")
        let saved = try Data(contentsOf: state)
        enum TransportFailure: Error { case stopped }
        XCTAssertThrowsError(try session.read(request: bytes("live-request.json"), now: 1791200932) { _, _ in
            throw TransportFailure.stopped
        }) { XCTAssertTrue($0 is TransportFailure) }
        XCTAssertEqual(try Data(contentsOf: state), saved)
    }

}
