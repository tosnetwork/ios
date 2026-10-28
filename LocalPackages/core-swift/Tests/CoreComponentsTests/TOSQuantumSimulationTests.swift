import XCTest
import CryptoKit
@testable import CoreComponents

final class TOSQuantumSimulationTests: XCTestCase {
    func testNativeSimulationUsesOriginalCheckpointAndExactLocalMessage() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "quantum-self-pay-simulation", withExtension: nil))
        func bytes(_ name: String) throws -> Data { try Data(contentsOf: fixture.appendingPathComponent(name)) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID(), anchor = try bytes("anchor.json"), request = try bytes("request.json")
        let message = try bytes("message.boc"), now = try XCTUnwrap(Int64(String(decoding: bytes("clock.txt"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: anchor, baseDirectory: base)
        let material = try [(1, "masterchain-info.tl"), (2, "chain-0000.tl"), (5, "account.tl")].map { kind, name in
            TOSQuantumProofBridge.Material(kind: UInt32(kind), bytes: try bytes("material/" + name))
        }
        var calls = 0
        let relay: TOSQuantumProofBridge.Transport = { query, capacity in
            calls += 1
            XCTAssertNil(query.range(of: message), "Signed message reached proof transport")
            let name: String
            switch query.count {
            case 4: name = "masterchain-info.tl"
            case 168: name = "chain-0000.tl"
            case 120: name = "account.tl"
            case 88:
                name = "exec-config.tl"
                XCTAssertEqual(capacity, 16 * 1024 * 1024)
            default: throw TOSPQError.invalidInput
            }
            let response = try bytes("material/" + name)
            XCTAssertLessThanOrEqual(response.count, capacity)
            return response
        }
        XCTAssertThrowsError(try session.simulate(request: request, now: now, signedMessage: message, transport: relay)) {
            XCTAssertEqual($0 as? TOSQuantumProofBridge.SimulationError, .native(-7))
        }
        XCTAssertEqual(calls, 0)
        _ = try session.enroll(request: request, now: now, material: material)
        let checkpoint = base.appendingPathComponent("quantum-proof-checkpoints/" + id.uuidString + "/checkpoint.json")
        let result = try session.simulate(request: request, now: now, signedMessage: message, transport: relay)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: result.encoded) as? [String: Any])
        XCTAssertEqual(value["scope"] as? String, "local_estimate")
        XCTAssertEqual(value["status"] as? String, "executed")
        XCTAssertEqual(value["message_bytes_hash"] as? String,
            Data(SHA256.hash(data: message)).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(calls, 3)
        let saved = try Data(contentsOf: checkpoint)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual((state["head"] as? [String: Any])?["seqno"] as? Int, 6)

        enum TransportFailure: Error { case stopped }
        XCTAssertThrowsError(try session.simulate(request: request, now: now, signedMessage: message) { _, _ in
            throw TransportFailure.stopped
        }) { XCTAssertTrue($0 is TransportFailure) }
        XCTAssertEqual(try Data(contentsOf: checkpoint), saved)
        XCTAssertThrowsError(try session.simulate(request: request, now: now + 3600, signedMessage: message, transport: relay)) {
            XCTAssertEqual($0 as? TOSQuantumProofBridge.SimulationError, .native(-2))
        }
        XCTAssertEqual(try Data(contentsOf: checkpoint), saved)

        try FileManager.default.removeItem(at: checkpoint)
        let beforeLostState = calls
        XCTAssertThrowsError(try session.simulate(request: request, now: now, signedMessage: message, transport: relay)) {
            XCTAssertEqual($0 as? TOSQuantumProofBridge.SimulationError, .native(-7))
        }
        XCTAssertEqual(calls, beforeLostState)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
    }

    func testSimulationRejectsEmptyMessageBeforeTransport() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let session = try TOSQuantumProofSession(walletID: UUID(), locallyProvisionedAnchor: Data([1]), baseDirectory: base)
        var called = false
        XCTAssertThrowsError(try session.simulate(request: Data([1]), now: 1, signedMessage: Data()) { _, _ in
            called = true
            return Data([1])
        }) { XCTAssertTrue($0 is TOSPQError) }
        XCTAssertFalse(called)
    }
}
