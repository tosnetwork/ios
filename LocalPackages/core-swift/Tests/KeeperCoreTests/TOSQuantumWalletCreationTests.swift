import XCTest
import CoreComponents
@testable import KeeperCore

final class TOSQuantumWalletCreationTests: XCTestCase {
    private let words = (Array(repeating: "abandon", count: 11) + ["amateur"])
    private enum Failure: Error { case injected }

    private func fixture() throws -> (TOSQuantumNetworkProfile, TOSQuantumSelfPayNetwork, Int64) {
        let base = try XCTUnwrap(Bundle.module.url(forResource: "quantum-self-pay-live", withExtension: nil))
        func read(_ name: String) throws -> Data { try Data(contentsOf: base.appendingPathComponent(name)) }
        let anchor = try XCTUnwrap(JSONSerialization.jsonObject(with: read("anchor.json")) as? [String: Any])
        let profile = try TOSQuantumNetworkProfile(globalID: 1,
            rootHash: XCTUnwrap(anchor["root_hash"] as? String), fileHash: XCTUnwrap(anchor["file_hash"] as? String))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: read("manifest.json")) as? [String: Any])
        let now = try XCTUnwrap(manifest["controlled_now"] as? NSNumber).int64Value
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try TOSQuantumProofSession(walletID: UUID(), locallyProvisionedAnchor: profile.anchor(), baseDirectory: directory)
        let replies = try ["masterchain-info.tl", "chain-0000.tl", "config.tl"].map { try read("policy/material/" + $0) }
        var cursor = 0
        let proof = try session.enrollBound(request: TOSQuantumSelfPayNetwork.request(maximumAge: 300), now: now) { _, capacity in
            guard cursor < replies.count, replies[cursor].count <= capacity else { throw Failure.injected }
            defer { cursor += 1 }; return replies[cursor]
        }
        XCTAssertEqual(cursor, replies.count)
        return (profile, try TOSQuantumSelfPayNetwork(proof: proof, expectedGlobalID: 1, now: now, maximumAge: 300), now)
    }

    func testProfileValidationAlsoAppliesToPersistedInput() throws {
        let hash = String(repeating: "42", count: 32)
        for invalid in ["", "42", String(repeating: "0", count: 64), String(repeating: "g", count: 64), "0x" + hash] {
            XCTAssertThrowsError(try TOSQuantumNetworkProfile(globalID: 1, rootHash: invalid, fileHash: hash))
            let bytes = try JSONSerialization.data(withJSONObject: ["globalID": 1, "rootHash": hash, "fileHash": invalid])
            XCTAssertThrowsError(try JSONDecoder().decode(TOSQuantumNetworkProfile.self, from: bytes))
        }
        for id in [Int32.min, -1, 1, Int32.max] {
            let profile = try TOSQuantumNetworkProfile(globalID: id, rootHash: hash, fileHash: hash.uppercased())
            XCTAssertEqual(try JSONDecoder().decode(TOSQuantumNetworkProfile.self, from: JSONEncoder().encode(profile)), profile)
        }
        let suite = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertThrowsError(try TOSQuantumNetworkProfile.selected(defaults: defaults))
        let profile = try TOSQuantumNetworkProfile(globalID: 1, rootHash: hash, fileHash: hash)
        try profile.select(defaults: defaults)
        XCTAssertEqual(try TOSQuantumNetworkProfile.selected(defaults: defaults), profile)
    }

    func testCreationPublishesOnlyAfterBothRealDerivedKeysAndRecoveryAreStored() async throws {
        let (profile, network, now) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var events = [String](), keys = [TOSQuantumRole: Data](), record: TOSQuantumCreationRecord?
        let creator = TOSQuantumWalletCreation(network: { _, _ in network }, storeRole: { id, role, context, seed in
            XCTAssertEqual(id, record?.id); XCTAssertEqual(context.network, network.namespace)
            XCTAssertEqual(context.globalID, 1); XCTAssertEqual(context.account, 0); XCTAssertEqual(context.generation, 0)
            let key = try TOSQuantumSigner.publicKey(role: role, seed: seed)
            keys[role] = key; seed.resetBytes(in: 0..<seed.count)
            events.append(role == .primary ? "primary" : "rescue")
            return key
        }, saveRecord: { value in
            record = value; try value.save(baseDirectory: directory); events.append("record")
        }, now: { now })
        try await creator.create(words: words, profile: profile, saveMnemonic: { _ in events.append("mnemonic") }, publish: { value in
            XCTAssertEqual(value.identity.wallet.initialAuthority.primaryKey, keys[.primary])
            XCTAssertEqual(value.identity.wallet.initialAuthority.rescueKey, keys[.rescue])
            XCTAssertEqual(value.identity.wallet.initialAuthority.namespace, network.namespace)
            events.append("publish")
        })
        XCTAssertEqual(events, ["record", "mnemonic", "primary", "rescue", "publish"])
        let saved = try XCTUnwrap(record)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("quantum-creation/\(saved.id.uuidString).json"))
        XCTAssertEqual(try JSONDecoder().decode(TOSQuantumCreationRecord.self, from: bytes).identity, saved.identity)
        XCTAssertThrowsError(try saved.save(baseDirectory: directory))
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        changed["account"] = 1
        XCTAssertThrowsError(try JSONDecoder().decode(TOSQuantumCreationRecord.self, from: JSONSerialization.data(withJSONObject: changed)))
    }

    func testEveryPersistenceFailurePropagatesAndPreventsLaterSteps() async throws {
        let (profile, network, now) = try fixture()
        let order = ["record", "mnemonic", "primary", "rescue", "publish"]
        for stop in order {
            var events = [String]()
            func step(_ name: String) throws {
                events.append(name)
                if name == stop { throw Failure.injected }
            }
            let creator = TOSQuantumWalletCreation(network: { _, _ in network }, storeRole: { _, role, _, seed in
                try step(role == .primary ? "primary" : "rescue")
                return try TOSQuantumSigner.publicKey(role: role, seed: seed)
            }, saveRecord: { _ in try step("record") }, now: { now }, completeRecord: { _ in try step("complete") })
            do {
                try await creator.create(words: words, profile: profile, saveMnemonic: { _ in try step("mnemonic") },
                                         publish: { _ in try step("publish") })
                XCTFail("Reported success after \(stop) failed")
            } catch Failure.injected {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(events, Array(order.prefix(through: try XCTUnwrap(order.firstIndex(of: stop)))))
        }
    }

    func testExpiredProofAndWrongStoredKeyCannotPublish() async throws {
        let (profile, network, timestamp) = try fixture()
        for expire in [true, false] {
            var now = timestamp, published = false
            let creator = TOSQuantumWalletCreation(network: { _, _ in network }, storeRole: { _, role, _, seed in
                let key = try TOSQuantumSigner.publicKey(role: role, seed: seed)
                if role == .rescue && expire { now += 301 }
                return expire ? key : Data(count: key.count)
            }, saveRecord: { _ in }, now: { now })
            do {
                try await creator.create(words: words, profile: profile, saveMnemonic: { _ in }, publish: { _ in published = true })
                XCTFail("Invalid custody or expired proof accepted")
            } catch TOSPQError.invalidInput {
                XCTAssertTrue(expire)
            } catch TOSPQError.keyBinding {
                XCTAssertFalse(expire)
            } catch { XCTFail("Unexpected refusal: \(error)") }
            XCTAssertFalse(published)
        }
    }

    func testNetworkFailureDoesNotWriteRecoveryOrCustody() async throws {
        let (profile, _, now) = try fixture()
        var writes = 0
        let creator = TOSQuantumWalletCreation(network: { _, _ in throw Failure.injected },
            storeRole: { _, _, _, _ in writes += 1; return Data() }, saveRecord: { _ in writes += 1 }, now: { now })
        do {
            try await creator.create(words: words, profile: profile, saveMnemonic: { _ in writes += 1 }, publish: { _ in writes += 1 })
            XCTFail("Unverified network accepted")
        } catch Failure.injected {}
        XCTAssertEqual(writes, 0)
    }
    func testResumePreservesUUIDBirthAnchorAndPartialRolesAcrossReload() async throws {
        let (profile, network, now) = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var saved: TOSQuantumCreationRecord?, keys = [TOSQuantumRole: Data](), failRescue = true
        var records = 0, mnemonicWrites = 0, publications = 0
        let creator = TOSQuantumWalletCreation(network: { _, _ in network }, storeRole: { _, role, _, seed in
            if role == .rescue && failRescue { throw Failure.injected }
            let key = try TOSQuantumSigner.publicKey(role: role, seed: seed)
            if let existing = keys[role] { XCTAssertEqual(existing, key) } else { keys[role] = key }
            return key
        }, saveRecord: { value in records += 1; saved = value; try value.save(baseDirectory: directory) }, now: { now },
        resumeNetwork: { id, retained in
            XCTAssertEqual(id, saved?.id); XCTAssertEqual(retained, profile)
            return network
        }, completeRecord: { try $0.markPublished(baseDirectory: directory) })
        do {
            try await creator.create(words: words, profile: profile, saveMnemonic: { _ in mnemonicWrites += 1 }, publish: { _ in XCTFail("Incomplete roles published") })
            XCTFail("Injected interruption ignored")
        } catch Failure.injected {}
        let original = try XCTUnwrap(saved), originalPrimary = try XCTUnwrap(keys[.primary])
        let loaded = try TOSQuantumCreationRecord.load(id: original.id, baseDirectory: directory)
        XCTAssertFalse(loaded.published)
        failRescue = false
        for _ in 0..<2 {
            try await creator.resume(words: words, record: loaded) { value in
                XCTAssertEqual(value.id, original.id); XCTAssertEqual(value.profile, original.profile)
                XCTAssertEqual(value.identity, original.identity); publications += 1
            }
        }
        XCTAssertTrue(try TOSQuantumCreationRecord.load(id: original.id, baseDirectory: directory).published)
        XCTAssertEqual(keys[.primary], originalPrimary)
        XCTAssertEqual(keys.count, 2); XCTAssertEqual(records, 1); XCTAssertEqual(mnemonicWrites, 1); XCTAssertEqual(publications, 2)
    }

    func testResumeChecksDerivedBirthKeysBeforeAnyCustodyWrites() async throws {
        let (profile, network, now) = try fixture()
        let authority = try TOSQuantumSelfPayAuthority(globalID: 1, namespace: network.namespace,
            primaryKey: Data(repeating: 7, count: 1312), rescueKey: Data(repeating: 8, count: 32))
        let record = try TOSQuantumCreationRecord(id: UUID(), profile: profile,
            identity: TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: authority)))
        let alteredPolicy = try TOSQuantumSelfPayAuthority(globalID: 1, namespace: network.namespace,
            primaryKey: authority.primaryKey, rescueKey: authority.rescueKey, policy: .required)
        XCTAssertThrowsError(try TOSQuantumCreationRecord(id: record.id, profile: profile,
            identity: TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: alteredPolicy))))
        var writes = 0
        let creator = TOSQuantumWalletCreation(network: { _, _ in network }, storeRole: { _, _, _, _ in writes += 1; throw Failure.injected },
            saveRecord: { _ in XCTFail("Resume replaced enrollment") }, now: { now })
        do {
            try await creator.resume(words: words, record: record) { _ in XCTFail("Wrong birth keys published") }
            XCTFail("Wrong phrase/identity binding accepted")
        } catch TOSPQError.keyBinding {} catch { XCTFail("Unexpected refusal: \(error)") }
        XCTAssertEqual(writes, 0)
    }

    func testResumeRefusesChangedNamespaceAndLateProofBeforePublish() async throws {
        let (profile, network, timestamp) = try fixture()
        var valid: TOSQuantumCreationRecord?
        let setup = TOSQuantumWalletCreation(network: { _, _ in network }, storeRole: { _, role, _, seed in
            try TOSQuantumSigner.publicKey(role: role, seed: seed)
        }, saveRecord: { valid = $0 }, now: { timestamp })
        try await setup.create(words: words, profile: profile, saveMnemonic: { _ in }, publish: { _ in })
        let original = try XCTUnwrap(valid)
        let a = original.identity.wallet.initialAuthority
        let changed = try TOSQuantumSelfPayAuthority(globalID: a.globalID, namespace: Data(repeating: 9, count: 32),
            primaryKey: a.primaryKey, rescueKey: a.rescueKey)
        let wrong = try TOSQuantumCreationRecord(id: original.id, profile: profile,
            identity: TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: changed)))
        var writes = 0, now = timestamp
        let creator = TOSQuantumWalletCreation(network: { _, _ in network }, storeRole: { _, role, _, seed in
            writes += 1; now = timestamp + 301
            return try TOSQuantumSigner.publicKey(role: role, seed: seed)
        }, saveRecord: { _ in XCTFail("Resume replaced enrollment") }, now: { now })
        do { try await creator.resume(words: words, record: wrong) { _ in XCTFail("Wrong namespace published") }; XCTFail("Wrong namespace accepted") }
        catch TOSPQError.keyBinding {} catch { XCTFail("Unexpected refusal: \(error)") }
        XCTAssertEqual(writes, 0)
        do { try await creator.resume(words: words, record: original) { _ in XCTFail("Expired proof published") }; XCTFail("Expired proof accepted") }
        catch TOSPQError.invalidInput {} catch { XCTFail("Unexpected refusal: \(error)") }
        XCTAssertEqual(writes, 2)
    }

    func testEnrollmentDirectoryIsBoundedAndRejectsTransplantedCorruptRecords() async throws {
        let (profile, network, now) = try fixture()
        var initial: TOSQuantumCreationRecord?
        let creator = TOSQuantumWalletCreation(network: { _, _ in network }, storeRole: { _, role, _, seed in
            try TOSQuantumSigner.publicKey(role: role, seed: seed)
        }, saveRecord: { initial = $0 }, now: { now })
        try await creator.create(words: words, profile: profile, saveMnemonic: { _ in }, publish: { _ in })
        let record = try XCTUnwrap(initial)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertTrue(try TOSQuantumCreationRecord.loadAll(baseDirectory: base).isEmpty)
        try record.save(baseDirectory: base)
        let file = base.appendingPathComponent("quantum-creation/\(record.id.uuidString).json")
        let bytes = try Data(contentsOf: file)
        let transplant = base.appendingPathComponent("quantum-creation/\(UUID().uuidString).json")
        try bytes.write(to: transplant)
        XCTAssertThrowsError(try TOSQuantumCreationRecord.loadAll(baseDirectory: base))
        try FileManager.default.removeItem(at: transplant)
        try (bytes + Data(repeating: 0x20, count: 32_769 - bytes.count)).write(to: file)
        XCTAssertThrowsError(try TOSQuantumCreationRecord.loadAll(baseDirectory: base))
        try bytes.write(to: file)
        try record.markPublished(baseDirectory: base)
        let completed = try Data(contentsOf: file)
        XCTAssertTrue(try TOSQuantumCreationRecord.load(id: record.id, baseDirectory: base).published)
        try record.markPublished(baseDirectory: base)
        XCTAssertEqual(try Data(contentsOf: file), completed)
        for _ in 1..<64 { try TOSQuantumCreationRecord(id: UUID(), profile: profile, identity: record.identity).save(baseDirectory: base) }
        XCTAssertEqual(try TOSQuantumCreationRecord.loadAll(baseDirectory: base).count, 64)
        XCTAssertThrowsError(try TOSQuantumCreationRecord(id: UUID(), profile: profile, identity: record.identity).save(baseDirectory: base))
        try bytes.write(to: transplant)
        XCTAssertThrowsError(try TOSQuantumCreationRecord.loadAll(baseDirectory: base))
    }

    func testEnrollmentCleanupIsIdempotentAndScoped() async throws {
        let (profile, network, now) = try fixture()
        var record: TOSQuantumCreationRecord?
        let creator = TOSQuantumWalletCreation(network: { _, _ in network }, storeRole: { _, role, _, seed in
            try TOSQuantumSigner.publicKey(role: role, seed: seed)
        }, saveRecord: { record = $0 }, now: { now })
        try await creator.create(words: words, profile: profile, saveMnemonic: { _ in }, publish: { _ in })
        let saved = try XCTUnwrap(record), other = try TOSQuantumCreationRecord(id: UUID(), profile: profile, identity: saved.identity)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try saved.save(baseDirectory: base); try other.save(baseDirectory: base)
        try TOSQuantumCreationRecord.remove(id: saved.id, baseDirectory: base)
        try TOSQuantumCreationRecord.remove(id: saved.id, baseDirectory: base)
        XCTAssertEqual(try TOSQuantumCreationRecord.loadAll(baseDirectory: base).map(\.id), [other.id])
        try TOSQuantumCreationRecord.removeAll(baseDirectory: base)
        try TOSQuantumCreationRecord.removeAll(baseDirectory: base)
        XCTAssertTrue(try TOSQuantumCreationRecord.loadAll(baseDirectory: base).isEmpty)
    }

    func testPublishedWalletIsNotReportedFailedWhenJournalCloseIsDeferred() async throws {
        let (profile, network, now) = try fixture()
        var published = 0, closes = 0
        let creator = TOSQuantumWalletCreation(network: { _, _ in network }, storeRole: { _, role, _, seed in
            try TOSQuantumSigner.publicKey(role: role, seed: seed)
        }, saveRecord: { _ in }, now: { now }, completeRecord: { _ in closes += 1; throw Failure.injected })
        try await creator.create(words: words, profile: profile, saveMnemonic: { _ in }, publish: { _ in published += 1 })
        XCTAssertEqual(published, 1); XCTAssertEqual(closes, 1)
    }

}
