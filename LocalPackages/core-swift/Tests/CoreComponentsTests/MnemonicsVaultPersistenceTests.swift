import XCTest
import TKKeychain
@testable import CoreComponents

final class MnemonicsVaultPersistenceTests: XCTestCase {
    private final class Storage: TKKeychainVault {
        var records = [String: Data](), writes = 0, rejectWrites = false, rejectReads = false
        func key(_ query: TKKeychainQuery) -> String {
            guard case let .genericPassword(service, account) = query.item else { preconditionFailure() }
            return service + "/" + (account ?? "")
        }
        private func read(_ query: TKKeychainQuery) throws -> Data {
            if rejectReads { throw TKKeychainError.other(-50) }
            guard let value = records[key(query)] else { throw TKKeychainError.noItem }
            return value
        }
        func get(query: TKKeychainQuery) throws -> Data { try read(query) }
        func get(query: TKKeychainQuery) throws -> String { String(decoding: try read(query), as: UTF8.self) }
        func get<T: Codable>(query: TKKeychainQuery) throws -> T { try JSONDecoder().decode(T.self, from: read(query)) }
        func set(_ value: Data, query: TKKeychainQuery) throws {
            writes += 1
            if rejectWrites { throw TKKeychainError.other(-50) }
            records[key(query)] = value
        }
        func set(_ value: String, query: TKKeychainQuery) throws { try set(Data(value.utf8), query: query) }
        func set<T: Codable>(_ value: T, query: TKKeychainQuery) throws { try set(JSONEncoder().encode(value), query: query) }
        func delete(_ query: TKKeychainQuery) throws {
            let prefix = key(query)
            if prefix.hasSuffix("/") { records = records.filter { !$0.key.hasPrefix(prefix) } }
            else { records.removeValue(forKey: prefix) }
        }
    }
    private func mnemonic() throws -> Mnemonic {
        try Mnemonic(mnemonicWords: Array(repeating: "abandon", count: 11) + ["amateur"])
    }
    private let atomic = "mnemonics_vault_fixture/encrypted_record_v2"
    private let count = "mnemonics_vault_fixture/encrypted_chunks_count"
    private let chunk = "mnemonics_vault_fixture/encrypted_chunk"

    func testNativeVaultMigratesLegacyChunksWithoutOverwritingThemAndUpdatesAtomically() async throws {
        let storage = Storage(), phrase = try mnemonic()
        let vault = MnemonicsVault(keychainVault: storage, seedProvider: { "fixture" })
        let originals = Dictionary(uniqueKeysWithValues: (0..<16).map { ("wallet-\($0)", phrase) })
        try await vault.addMnemoncs(originals, password: "public test password")
        XCTAssertEqual(storage.writes, 1)
        let encrypted = try XCTUnwrap(storage.records.removeValue(forKey: atomic))
        let chunks = stride(from: 0, to: encrypted.count, by: 2048).map { encrypted.subdata(in: $0..<min($0 + 2048, encrypted.count)) }
        XCTAssertGreaterThan(chunks.count, 1)
        storage.records[count] = try JSONEncoder().encode(chunks.count)
        for (index, bytes) in chunks.enumerated() { storage.records[chunk + String(index)] = bytes }
        let legacy = storage.records
        let initial = try await vault.getMnemonics(password: "public test password")
        XCTAssertEqual(initial.count, 16)
        storage.rejectWrites = true; storage.writes = 0
        do { try await vault.addMnemonic(phrase, identifier: "new", password: "public test password"); XCTFail("Write failure accepted") }
        catch TKKeychainError.other(-50) {}
        XCTAssertEqual(storage.writes, 1, "Failed writes must not fall back to a replacement vault")
        XCTAssertEqual(storage.records, legacy)
        storage.rejectWrites = false
        try await vault.addMnemonic(phrase, identifier: "new", password: "public test password")
        let updated = try await vault.getMnemonics(password: "public test password")
        XCTAssertEqual(updated.count, 17)
        for (key, bytes) in legacy { XCTAssertEqual(storage.records[key], bytes) }
        let committed = storage.records
        storage.rejectWrites = true
        do { try await vault.changePassword(oldPassword: "public test password", newPassword: "new test password"); XCTFail("Write failure accepted") }
        catch TKKeychainError.other(-50) {}
        XCTAssertEqual(storage.records, committed)
        let retained = try await vault.getMnemonics(password: "public test password")
        XCTAssertEqual(retained.count, 17)
    }

    func testWrongPasswordAndCorruptionNeverReinitializeEitherVault() async throws {
        for rn in [false, true] {
            let storage = Storage(), phrase = try mnemonic()
            let native = MnemonicsVault(keychainVault: storage, seedProvider: { "fixture" })
            let legacy = RNMnemonicsVault(keychainVault: storage)
            func add(_ id: String, _ password: String) async throws {
                if rn { try await legacy.addMnemonic(phrase, identifier: id, password: password) }
                else { try await native.addMnemonic(phrase, identifier: id, password: password) }
            }
            try await add("existing", "public test password")
            let before = storage.records; storage.writes = 0
            do { try await add("new", "wrong password"); XCTFail("Wrong password replaced recovery material") } catch {}
            XCTAssertEqual(storage.writes, 0); XCTAssertEqual(storage.records, before)
            let target = rn ? "app/wallets_chunk_0" : atomic
            storage.records[target] = Data("corrupt public test record".utf8)
            let corrupt = storage.records
            XCTAssertTrue(rn ? legacy.hasMnemonics() : native.hasMnemonics())
            do { try await add("new", "public test password"); XCTFail("Corruption replaced recovery material") } catch {}
            XCTAssertEqual(storage.writes, 0); XCTAssertEqual(storage.records, corrupt)
        }
    }

    func testInaccessibleOrMalformedVaultIsNotAnEmptyInstallation() async throws {
        let storage = Storage()
        let native = MnemonicsVault(keychainVault: storage, seedProvider: { "fixture" })
        let legacy = RNMnemonicsVault(keychainVault: storage)
        XCTAssertFalse(native.hasMnemonics()); XCTAssertFalse(legacy.hasMnemonics())
        storage.rejectReads = true
        XCTAssertTrue(native.hasMnemonics()); XCTAssertTrue(legacy.hasMnemonics())
        storage.rejectReads = false
        for invalid in [-1, 0, 513, Int.max] {
            storage.records[count] = try JSONEncoder().encode(invalid)
            storage.records["app/wallets_chunks"] = try JSONEncoder().encode(invalid)
            XCTAssertTrue(native.hasMnemonics()); XCTAssertTrue(legacy.hasMnemonics())
            do { _ = try await native.getMnemonics(password: "unused"); XCTFail("Invalid count accepted") }
            catch MnemonicsVault.Error.mnemonicsCorrupted {}
            do { _ = try await legacy.getMnemonics(password: "unused"); XCTFail("Invalid count accepted") }
            catch RNMnemonicsVault.Error.mnemonicsCorrupted {}
        }
        storage.records[atomic] = Data("corrupt".utf8)
        do { _ = try await native.getMnemonics(password: "unused"); XCTFail("Corrupt record fell back to legacy chunks") }
        catch is DecodingError {}
        XCTAssertEqual(storage.writes, 0)
    }
}
