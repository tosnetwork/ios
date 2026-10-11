import XCTest
import Foundation
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSQuantumProofCoordinatorTests: XCTestCase {
    private func birth() throws -> TOSQuantumGenesis {
        let c = try TOSQuantumReviewCandidate.load()
        var fee = Data(count: 60); fee.replaceSubrange(0..<12, with: [0,0,0,1,0,0,0,8,0,0,0,3])
        return try TOSQuantumGenesis(codes: c.codes, pins: c.pins, globalId: 1, network: TOSQuantumReviewCandidate.network,
            walletId: 42, primaryKey: Data(repeating: 0x11, count: 1312), rescueKey: Data(repeating: 0x22, count: 32),
            policy: .required, feeTreeId: Data(repeating: 7, count: 32), feePublicKey: fee, epoch0: 100)
    }
    func testCancellationDiscardsReplyAndReleasesCheckpointLock() async throws {
        let anchor = Data("{\"kind\":\"zerostate\",\"workchain\":-1,\"shard\":\"8000000000000000\",\"seqno\":0,\"root_hash\":\"1BDB1208416A1103BDB7FF6082F7EFFE047BAC45313E27D4043CA04D16377B64\",\"file_hash\":\"C9F382C9119EB7F3AB3BD6AE88FA1AF59AB500BDA3B5D794480E83EE24477686\"}".utf8)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID(), b = try birth(), started = expectation(description: "query entered")
        let release = DispatchSemaphore(value: 0)
        let worker = try TOSQuantumProofCoordinator(id: id, anchor: anchor, birth: b, successor: nil, transport: { _, _ in
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            guard release.wait(timeout: .now() + 10) == .success else { throw TOSPQError.invalidInput }
            return Data([1,2,3,4])
        }, maximumAge: 30, baseDirectory: base)
        let task = Task { try await worker.observe(initialize: true, primaryExecution: false) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel(); release.signal()
        do { _ = try await task.value; XCTFail("Cancelled observation returned") }
        catch { XCTAssertTrue(error is CancellationError, "Cancellation did not reach native acquisition") }
        let state = base.appendingPathComponent("quantum-proof-checkpoints/" + id.uuidString + "/checkpoint.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        enum Probe: Error { case released }
        let next = try TOSQuantumProofCoordinator(id: id, anchor: anchor, birth: b, successor: nil,
            transport: { _, _ in throw Probe.released }, maximumAge: 30, baseDirectory: base)
        do { _ = try await next.observe(initialize: true, primaryExecution: false); XCTFail("Lock probe returned") }
        catch { XCTAssertTrue(error is Probe, "Cancelled operation retained checkpoint lock") }
    }
}
