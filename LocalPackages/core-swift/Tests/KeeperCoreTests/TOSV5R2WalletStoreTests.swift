import XCTest
import Foundation
import TonSwift
import CoreComponents
@testable import KeeperCore

private actor R2AuthenticationProbe {
    private var calls = 0
    func accept() -> Bool { calls += 1; return true }
    func count() -> Int { calls }
}

final class TOSV5R2WalletStoreTests: XCTestCase {
    func testInitialRegistryAuthenticationAndDuplicateIdentity() async throws {
        let suite = "v5r2-qa-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bundle = try TOSV5R2ReviewCandidate.load()
        let d = TOSV5R2InitialRecovery.Derivation(account: 0, generation: 0, primary: .rawMaster32, rescue: .rawMaster32, fee: .rawMaster32)
        let fee: Data = Data(hex: "000000010000000800000003" + String(repeating: "33", count: 16) + String(repeating: "44", count: 32))
        let m = try TOSV5R2InitialRecovery.prepare(codes: bundle.codes, pins: bundle.pins, globalId: 1, network: TOSV5R2ReviewCandidate.network,
            walletId: 42, primaryKey: Data(repeating: 0x11, count: 1312), rescueKey: Data(repeating: 0x22, count: 32), policy: .required,
            tree: Data(repeating: 7, count: 32), feeKey: fee, epoch0: 100, derivation: d)
        let denied = try TOSV5R2WalletStore(defaults: defaults, authenticate: { false })
        do { _ = try await denied.registerInitial(name: "cancelled", manifest: m.toJson(), independentlyKnownWallet: m.genesis.address); XCTFail("cancelled registration accepted") }
        catch { guard let error = error as? TOSPQError, case .keyBinding = error else { throw error } }
        let empty = try await denied.list(); XCTAssertTrue(empty.isEmpty)
        let allowed = try TOSV5R2WalletStore(defaults: defaults, authenticate: { true })
        let record = try await allowed.registerInitial(name: "QA R2", manifest: m.toJson(), independentlyKnownWallet: m.genesis.address)
        let reopened = try TOSV5R2WalletStore(defaults: defaults, authenticate: { true })
        let records = try await reopened.list(); XCTAssertEqual(records.map(\.id), [record.id])
        let anchor = Data("{\"kind\":\"zerostate\",\"workchain\":-1,\"shard\":\"8000000000000000\",\"seqno\":0,\"root_hash\":\"1BDB1208416A1103BDB7FF6082F7EFFE047BAC45313E27D4043CA04D16377B64\",\"file_hash\":\"C9F382C9119EB7F3AB3BD6AE88FA1AF59AB500BDA3B5D794480E83EE24477686\"}".utf8)
        let proofDirectory = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("v5r2-proof-checkpoints/" + record.id.uuidString)
        defer { try? FileManager.default.removeItem(at: proofDirectory) }
        let noQueries: TOSV5R2ProofBridge.Transport = { _, _ in XCTFail("Missing/auth-refused observation queried endpoint"); throw TOSPQError.keyBinding }
        let actions = try Builder().endCell()
        let deadline = UInt32(Date().timeIntervalSince1970) + 120
        do {
            _ = try await denied.preparePrimaryExecute(id: record.id, independentlyKnownWallet: m.genesis.address,
                locallyProvisionedAnchor: anchor, initialize: false, actions: actions, validUntil: deadline, transport: noQueries)
            XCTFail("Unauthenticated PRIMARY preparation accepted")
        } catch { guard let error = error as? TOSPQError, case .keyBinding = error else { XCTFail("PRIMARY authentication gate bypassed"); throw error } }
        do {
            _ = try await allowed.preparePrimaryExecute(id: record.id, independentlyKnownWallet: m.genesis.address,
                locallyProvisionedAnchor: anchor, initialize: false, actions: actions, validUntil: deadline, transport: noQueries)
            XCTFail("PRIMARY preparation accepted missing checkpoint")
        } catch { guard let error = error as? TOSPQError, case .invalidInput = error else { throw error } }

        do {
            _ = try await denied.observeInitial(id: record.id, independentlyKnownWallet: m.genesis.address, locallyProvisionedAnchor: anchor,
                initialize: false, primaryExecution: false, transport: noQueries)
            XCTFail("Unauthenticated proof observation accepted")
        } catch { guard let error = error as? TOSPQError, case .keyBinding = error else { XCTFail("Proof authentication gate bypassed"); throw error } }
        do {
            _ = try await allowed.observeInitial(id: record.id, independentlyKnownWallet: m.genesis.address, locallyProvisionedAnchor: anchor,
                initialize: false, primaryExecution: false, transport: noQueries)
            XCTFail("Missing checkpoint accepted")
        } catch { guard let error = error as? TOSPQError, case .invalidInput = error else { throw error } }

        do { _ = try await allowed.registerInitial(name: "duplicate", manifest: m.toJson(), independentlyKnownWallet: m.genesis.address); XCTFail("duplicate accepted") }
        catch { guard let error = error as? TOSPQError, case .keyBinding = error else { throw error } }
        let duplicateOutcomes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<8 {
                group.addTask {
                    do {
                        let other = try TOSV5R2WalletStore(defaults: defaults, authenticate: { true })
                        _ = try await other.registerInitial(name: "concurrent \(index)", manifest: m.toJson(), independentlyKnownWallet: m.genesis.address)
                        return true
                    } catch { return false }
                }
            }
            var accepted = 0
            for await acceptedWrite in group { if acceptedWrite { accepted += 1 } }
            return accepted
        }
        XCTAssertEqual(duplicateOutcomes, 0)
        let afterConcurrent = try await allowed.list(); XCTAssertEqual(afterConcurrent.map(\.id), [record.id])
        var master = Data(repeating: 9, count: 32)
        do { _ = try await denied.restoreInitialRole(id: record.id, independentlyKnownWallet: m.genesis.address, role: .primary, master: &master, inputProfile: .rawMaster32); XCTFail("cancelled restore accepted") }
        catch { guard let error = error as? TOSPQError, case .keyBinding = error else { throw error } }
        XCTAssertEqual(master, Data(count: 32))
        defaults.removePersistentDomain(forName: suite)
        let firstWrites = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<16 {
                group.addTask {
                    do {
                        let other = try TOSV5R2WalletStore(defaults: defaults, authenticate: { await Task.yield(); return true })
                        _ = try await other.registerInitial(name: "first \(index)", manifest: m.toJson(), independentlyKnownWallet: m.genesis.address)
                        return true
                    } catch { return false }
                }
            }
            var accepted = 0
            for await result in group { if result { accepted += 1 } }
            return accepted
        }
        XCTAssertEqual(firstWrites, 1)
        let afterFirstWrites = try await allowed.list(); XCTAssertEqual(afterFirstWrites.count, 1)
        defaults.removePersistentDomain(forName: suite)
        let cancelled = Task {
            try await allowed.registerInitial(name: "cancelled task", manifest: m.toJson(), independentlyKnownWallet: m.genesis.address)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("cancelled task persisted") }
        catch { XCTAssertTrue(error is CancellationError) }
        let afterCancellation = try await allowed.list(); XCTAssertTrue(afterCancellation.isEmpty)
        let cancelsDuringAuthentication = try TOSV5R2WalletStore(defaults: defaults, authenticate: {
            withUnsafeCurrentTask { $0?.cancel() }
            return true
        })
        let cancelledDuring = Task {
            try await cancelsDuringAuthentication.registerInitial(name: "cancelled during auth", manifest: m.toJson(), independentlyKnownWallet: m.genesis.address)
        }
        do { _ = try await cancelledDuring.value; XCTFail("authentication cancellation persisted") }
        catch { XCTAssertTrue(error is CancellationError) }
        let afterAuthenticationCancellation = try await allowed.list(); XCTAssertTrue(afterAuthenticationCancellation.isEmpty)
        let probe = R2AuthenticationProbe()
        let probesAuthentication = try TOSV5R2WalletStore(defaults: defaults, authenticate: { await probe.accept() })
        let cancelledBefore = Task {
            try await probesAuthentication.registerInitial(name: "cancelled before auth", manifest: m.toJson(), independentlyKnownWallet: m.genesis.address)
        }
        cancelledBefore.cancel()
        do { _ = try await cancelledBefore.value; XCTFail("pre-auth cancellation persisted") }
        catch { XCTAssertTrue(error is CancellationError) }
        let prompted = await probe.count(); XCTAssertEqual(prompted, 0, "Cancelled task must not prompt authentication")




    }
}
