import XCTest
import TonSwift
import CoreComponents
import Darwin
@testable import KeeperCore

final class TOSQuantumOutboxTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func input() throws -> (TOSQuantumSelfPayIdentity, TOSQuantumNetworkProfile, TOSQuantumSelfPayRequest, Data) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tos-quantum-self-pay", withExtension: "json"))
        let v = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func bytes(_ key: String) throws -> Data { Data(hex: try XCTUnwrap(v[key] as? String)) }
        let authority = try TOSQuantumSelfPayAuthority(globalID: 42, namespace: bytes("namespace"),
            primaryKey: bytes("primary_key"), rescueKey: bytes("rescue_key"))
        let identity = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: authority))
        let request = try TOSQuantumSelfPayRequest(wallet: identity.address,
            state: TOSQuantumSelfPayState(authority: authority), role: .rescue,
            validUntil: 1780000600, action: .lockPrimary, provenTime: 1780000000)
        let rows = try XCTUnwrap(v["cases"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { ($0["role"] as? Int) == 2 && ($0["kind"] as? Int) == 3 })
        let signature: Data = Data(hex: try XCTUnwrap(row["signature"] as? String))
        XCTAssertTrue(TOSQuantumSigner.verify(role: .rescue, purpose: .selfPay,
            publicKey: authority.rescueKey, digest: request.digest, signature: signature))
        return (identity, try TOSQuantumNetworkProfile(globalID: 42,
            rootHash: String(repeating: "1", count: 64), fileHash: String(repeating: "2", count: 64)), request, signature)
    }

    func testReopenRetainsExactSignedMessageAndNeverUnlocksOnUnknown() throws {
        let (identity, profile, request, signature) = try input()
        let outbox = try TOSQuantumOutbox(baseDirectory: directory)
        let entry = try outbox.reserve(identity: identity, profile: profile, request: request, deploy: true)
        XCTAssertThrowsError(try outbox.finishSigning(entry, signature: signature))
        XCTAssertThrowsError(try outbox.beginSubmission(entry))
        try outbox.beginSigning(entry)
        let reopened = try TOSQuantumOutbox(baseDirectory: directory)
        XCTAssertEqual(try reopened.pending(identity: identity)?.phase, .signing)
        XCTAssertThrowsError(try reopened.cancelUnsigned(entry))
        XCTAssertThrowsError(try reopened.beginSigning(entry))
        XCTAssertThrowsError(try reopened.finishSigning(entry, signature: Data()))
        try reopened.finishSigning(entry, signature: signature)
        let expectedCell = try identity.wallet.external(body: request.submission(signature: signature), deploy: true)
        let expected = try reopened.beginSubmission(entry)
        XCTAssertEqual(try TOSRPCOrdinaryBOC.decode(expected.base64EncodedString()).hash(), expectedCell.hash())
        let crashed = try TOSQuantumOutbox(baseDirectory: directory)
        XCTAssertEqual(try crashed.pending(identity: identity)?.phase, .submitting)
        XCTAssertEqual(try crashed.beginSubmission(entry), expected)
        try crashed.markUnknown(entry)
        XCTAssertEqual(try crashed.beginSubmission(entry), expected)
        XCTAssertThrowsError(try crashed.cancelUnsigned(entry))
        XCTAssertThrowsError(try crashed.reserve(identity: identity, profile: profile, request: request, deploy: false))
    }

    func testOnlyUnsignedCancellationReleasesAndStaleHandleCannotTouchNewEntry() throws {
        let (identity, profile, request, _) = try input()
        let outbox = try TOSQuantumOutbox(baseDirectory: directory)
        let first = try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false)
        try outbox.cancelUnsigned(first)
        XCTAssertNil(try outbox.pending(identity: identity))
        let second = try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertThrowsError(try outbox.cancelUnsigned(first))
        XCTAssertThrowsError(try outbox.beginSigning(first))
        XCTAssertEqual(try outbox.pending(identity: identity)?.id, second.id)
    }

    func testAlternativeAnchorAndRoleCannotBypassWalletSlot() throws {
        let (identity, profile, request, _) = try input()
        let outbox = try TOSQuantumOutbox(baseDirectory: directory)
        _ = try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false)
        let otherProfile = try TOSQuantumNetworkProfile(globalID: 42,
            rootHash: String(repeating: "3", count: 64), fileHash: profile.fileHash)
        let state = try TOSQuantumSelfPayState(authority: identity.wallet.initialAuthority)
        let policy = try Builder().store(uint: 0xa1, bits: 8).store(data: state.authority.namespace)
            .store(uint: 0, bits: 64).store(uint: 0, bits: 16).store(bit: false)
            .store(data: Data(hex: "5e4380aedc95f8cb72de55f7506de0269b47c03ad1d1ed0e5184c332544262c0")).endCell()
        let otherRequest = try TOSQuantumSelfPayRequest(wallet: identity.address, state: state, role: .primary,
            validUntil: 1780000601, action: .execute(Builder().endCell()), provenTime: 1780000000, primaryPolicy: policy)
        let other = try TOSQuantumOutbox(baseDirectory: directory)
        XCTAssertThrowsError(try other.reserve(identity: identity, profile: otherProfile, request: otherRequest, deploy: true))
        XCTAssertThrowsError(try other.reserve(identity: identity,
            profile: TOSQuantumNetworkProfile(globalID: 43, rootHash: profile.rootHash, fileHash: profile.fileHash),
            request: request, deploy: false))
    }

    func testConcurrentInstancesReserveExactlyOnce() throws {
        let (identity, profile, request, _) = try input()
        let stores = try (0..<8).map { _ in try TOSQuantumOutbox(baseDirectory: directory) }
        let lock = NSLock(); var winners = 0
        DispatchQueue.concurrentPerform(iterations: stores.count) { index in
            if (try? stores[index].reserve(identity: identity, profile: profile, request: request, deploy: false)) != nil {
                lock.lock(); winners += 1; lock.unlock()
            }
        }
        XCTAssertEqual(winners, 1)
        XCTAssertNotNil(try stores[0].pending(identity: identity))
    }

    func testCorruptOversizedAndInterruptedFilesFailClosed() throws {
        let (identity, profile, request, _) = try input()
        let outbox = try TOSQuantumOutbox(baseDirectory: directory)
        let entry = try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        let original = try Data(contentsOf: file)
        for bad in [Data("{".utf8), Data(count: 2 * 1024 * 1024 + 1)] {
            try bad.write(to: file)
            XCTAssertThrowsError(try outbox.pending(identity: identity))
            XCTAssertThrowsError(try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false))
        }
        try original.write(to: file)
        try outbox.cancelUnsigned(entry)
        try Data("interrupted".utf8).write(to: directory.appendingPathComponent("crash.pending"))
        XCTAssertThrowsError(try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false))
    }

    func testPersistenceFailureNeverReturnsBroadcastBytes() throws {
        let (identity, profile, request, signature) = try input()
        let outbox = try TOSQuantumOutbox(baseDirectory: directory)
        let entry = try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false)
        try outbox.beginSigning(entry)
        try outbox.finishSigning(entry, signature: signature)
        // Real filesystem failure, without a production test hook: replace directory by a file.
        let moved = directory.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: directory, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try Data().write(to: directory)
        XCTAssertThrowsError(try outbox.beginSubmission(entry))
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        XCTAssertEqual(try outbox.pending(identity: identity)?.phase, .signed)
    }

    func testInterruptedPublicationBlocksRetriesWithoutAccumulatingFiles() throws {
        let (identity, profile, request, signature) = try input()
        let outbox = try TOSQuantumOutbox(baseDirectory: directory)
        let entry = try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false)
        try outbox.beginSigning(entry)
        try outbox.finishSigning(entry, signature: signature)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        // A pre-existing pending file models an interrupted failed publication and
        // must block every later operation before another temporary is allocated.
        let pending = directory.appendingPathComponent("interrupted.pending")
        try Data(contentsOf: file).write(to: pending)
        for _ in 0..<8 {
            XCTAssertThrowsError(try outbox.beginSubmission(entry))
            XCTAssertThrowsError(try outbox.finishSigning(entry, signature: signature))
            XCTAssertThrowsError(try outbox.cancelUnsigned(entry))
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "pending" }.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: pending))
    }

    func testIndependentFileDescriptorLockPreventsReservation() throws {
        let (identity, profile, request, _) = try input()
        let outbox = try TOSQuantumOutbox(baseDirectory: directory)
        let fd = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false))
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertNoThrow(try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false))
    }

    func testFileCapacityPermissionsAndBackupExclusion() throws {
        let (identity, profile, request, _) = try input()
        let outbox = try TOSQuantumOutbox(baseDirectory: directory)
        for index in 0..<64 { try Data().write(to: directory.appendingPathComponent("old-\(index).json")) }
        XCTAssertThrowsError(try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("old-0.json"))
        _ = try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).first { !$0.lastPathComponent.hasPrefix("old-") && $0.pathExtension == "json" })
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testCompleteDataProtectionOnDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Simulator does not expose device Data Protection attributes; physical-device gate remains open")
        #else
        let (identity, profile, request, _) = try input()
        let outbox = try TOSQuantumOutbox(baseDirectory: directory)
        _ = try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
        #endif
    }

    func testUnwritableDirectoryPreventsPublishingBroadcastAttempt() throws {
        let (identity, profile, request, signature) = try input()
        let outbox = try TOSQuantumOutbox(baseDirectory: directory)
        let entry = try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false)
        try outbox.beginSigning(entry)
        try outbox.finishSigning(entry, signature: signature)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try outbox.beginSubmission(entry))
        XCTAssertEqual(try outbox.pending(identity: identity)?.phase, .signed)
    }

    func testSignerRunsOnlyAfterDurableReservationAndCannotRunTwice() throws {
        let (identity, profile, request, signature) = try input()
        let outbox = try TOSQuantumOutbox(baseDirectory: directory)
        let entry = try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false)
        var calls = 0
        func signer(_ stored: TOSQuantumOutbox.Entry) throws -> Data {
            calls += 1
            let reopened = try TOSQuantumOutbox(baseDirectory: directory)
            XCTAssertEqual(try reopened.pending(identity: identity)?.phase, .signing)
            XCTAssertEqual(stored.requestHash, request.digest)
            return signature
        }
        try outbox.signReserved(entry, signer: signer)
        XCTAssertThrowsError(try outbox.signReserved(entry, signer: signer))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try outbox.pending(identity: identity)?.phase, .signed)
    }

    func testStorageFailureNeverInvokesSignerAndSignerFailureKeepsSlot() throws {
        let (identity, profile, request, _) = try input()
        let outbox = try TOSQuantumOutbox(baseDirectory: directory)
        let entry = try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false)
        var calls = 0
        func signer(_ stored: TOSQuantumOutbox.Entry) throws -> Data {
            calls += 1; throw CancellationError()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try outbox.signReserved(entry, signer: signer))
        XCTAssertEqual(calls, 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try outbox.signReserved(entry, signer: signer))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try outbox.pending(identity: identity)?.phase, .signing)
        XCTAssertThrowsError(try outbox.cancelUnsigned(entry))
        XCTAssertThrowsError(try outbox.signReserved(entry, signer: signer))
        XCTAssertEqual(calls, 1)
    }

    func testCompleteSignedRecordCapacityIsCheckedBeforeTakingSlot() throws {
        let (identity, profile, _, _) = try input()
        // A shallow ordinary DAG fits the unsigned 1MiB limit, but two encoded
        // BOCs plus the signature cannot fit the durable 2MiB record.
        var level = try (0..<6500).map { index in
            try Builder().store(uint: index, bits: 32).store(data: Data(count: 120)).endCell()
        }
        while level.count > 1 {
            level = try stride(from: 0, to: level.count, by: 4).map { start in
                let builder = Builder()
                for cell in level[start..<min(start + 4, level.count)] { try builder.store(ref: cell) }
                return try builder.endCell()
            }
        }
        let actions = try Builder().store(uint: 0x0ec3c86d, bits: 32).store(uint: 3, bits: 8)
            .store(ref: Builder().endCell()).store(ref: XCTUnwrap(level.first)).endCell()
        let request = try TOSQuantumSelfPayRequest(wallet: identity.address,
            state: TOSQuantumSelfPayState(authority: identity.wallet.initialAuthority), role: .rescue,
            validUntil: 1780000600, action: .execute(actions), provenTime: 1780000000)
        let boc = try request.request.toBoc()
        XCTAssertLessThan(boc.count, 1024 * 1024)
        XCTAssertNoThrow(try TOSRPCOrdinaryBOC.decode(boc.base64EncodedString()))
        let outbox = try TOSQuantumOutbox(baseDirectory: directory)
        XCTAssertThrowsError(try outbox.reserve(identity: identity, profile: profile, request: request, deploy: false)) { error in
            guard case TOSQuantumOutbox.Error.capacity = error else { return XCTFail("Expected complete record capacity refusal, got \(error)") }
        }
        XCTAssertNil(try outbox.pending(identity: identity))
    }
}
