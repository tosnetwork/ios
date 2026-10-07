import XCTest
import Foundation
import TonSwift
import CoreComponents
@testable import KeeperCore

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

    }
}
