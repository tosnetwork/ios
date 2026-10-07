import Foundation
import TonSwift
import CoreComponents

public struct TOSV5R2WalletRecord: Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let manifest: Data
    public let initialWalletHash: Data
    public var address: Address { Address(workchain: 0, hash: initialWalletHash) }
}

/// Public initial registry. Import/secret access requires authentication; no current authority or readiness is inferred.
public actor TOSV5R2WalletStore {
    private static let registryLock = NSLock()
    private static func locked<T>(_ body: () throws -> T) rethrows -> T {
        registryLock.lock(); defer { registryLock.unlock() }; return try body()
    }
    private let defaults: UserDefaults
    private let authenticate: @MainActor () async throws -> Bool
    private let keychain = TOSV5R2SeedKeychain()
    private let codes: TOSV5R2Codes
    private let pins: TOSV5R2CodePins
    private let registry = "network.tos.wallet.v5r2.registry.v1"
    public init(defaults: UserDefaults = .standard, authenticate: @escaping @MainActor () async throws -> Bool) throws {
        let bundle = try TOSV5R2ReviewCandidate.load()
        self.defaults = defaults; self.authenticate = authenticate; codes = bundle.codes; pins = bundle.pins
    }
    public func list() throws -> [TOSV5R2WalletRecord] { try Self.locked { try readRecords() } }
    private func readRecords() throws -> [TOSV5R2WalletRecord] {
        guard let data = defaults.data(forKey: registry) else { return [] }
        guard data.count <= 2 * 1024 * 1024 else { throw TOSPQError.invalidInput }
        let records: [TOSV5R2WalletRecord]
        do { records = try JSONDecoder().decode([TOSV5R2WalletRecord].self, from: data) }
        catch { throw TOSPQError.invalidInput }
        guard records.count <= 64, Set(records.map(\.id)).count == records.count,
              Set(records.map(\.initialWalletHash)).count == records.count else { throw TOSPQError.keyBinding }
        for record in records {
            guard !record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, record.name.utf8.count <= 128,
                  record.initialWalletHash.count == 32 else { throw TOSPQError.invalidInput }
            _ = try TOSV5R2InitialRecovery.parseAndReconstruct(record.manifest, codes: codes, pins: pins, expectedWallet: record.address)
            try TOSV5R2ReviewCandidate.requireChain(manifest: record.manifest)
        }
        return records
    }
    private func save(_ records: [TOSV5R2WalletRecord]) throws {
        defaults.set(try JSONEncoder().encode(records), forKey: registry)
    }
    private func unlock() async throws {
        try Task.checkCancellation()
        guard try await authenticate() else { throw TOSPQError.keyBinding }
        try Task.checkCancellation()
    }
    public func registerInitial(name: String, manifest: Data, independentlyKnownWallet: Address) async throws -> TOSV5R2WalletRecord {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128 else { throw TOSPQError.invalidInput }
        let parsed = try TOSV5R2InitialRecovery.parseAndReconstruct(manifest, codes: codes, pins: pins, expectedWallet: independentlyKnownWallet)
        try TOSV5R2ReviewCandidate.requireChain(manifest: parsed.toJson())
        try await unlock()
        return try Self.locked {
            var records = try readRecords()
            guard records.count < 64, !records.contains(where: { $0.initialWalletHash == independentlyKnownWallet.hash }) else { throw TOSPQError.keyBinding }
            let record = TOSV5R2WalletRecord(id: UUID(), name: name, manifest: parsed.toJson(), initialWalletHash: independentlyKnownWallet.hash)
            records.append(record); try save(records); return record
        }
    }
    /// Initial role binding only. Native mnemonic validation precedes this call; master is consumed on every return.
    public func restoreInitialRole(id: UUID, independentlyKnownWallet: Address, role: TOSV5R2Role, master: inout Data,
                                   inputProfile: TOSV5R2SeedKeychain.MasterProfile) async throws -> Data {
        defer { master.resetBytes(in: 0..<master.count) }
        try await unlock()
        guard let record = try list().first(where: { $0.id == id }), record.address == independentlyKnownWallet else { throw TOSPQError.keyBinding }
        let initial = try TOSV5R2InitialRecovery.parseAndReconstruct(record.manifest, codes: codes, pins: pins, expectedWallet: independentlyKnownWallet)
        guard let object = try JSONSerialization.jsonObject(with: record.manifest) as? [String: Any],
              let network = object["network"] as? String, let global = object["global_id"] as? NSNumber,
              let publicText = object[role == .primary ? "primary_key" : "rescue_key"] as? String else { throw TOSPQError.invalidInput }
        let d = initial.derivation
        let context = try TOSV5R2SeedKeychain.Context(network: Data(hex: network), globalID: global.int32Value,
                                                     account: d.account_index, generation: d.key_generation)
        let profile = role == .primary ? d.primary_seed_profile : d.rescue_seed_profile
        return try keychain.restoreDerivedAndWipe(id: id, role: role, context: context, master: &master, inputProfile: inputProfile,
            declaredProfile: profile == .nativeMnemonic ? .nativeMnemonic : .rawMaster32, expectedPublicKey: Data(hex: publicText))
    }
    /// Anchor comes from locally authenticated provisioning; initialize is explicit first enrollment only.
    public func observeInitial(id: UUID, independentlyKnownWallet: Address, locallyProvisionedAnchor: Data,
                               initialize: Bool, primaryExecution: Bool, transport: @escaping TOSV5R2ProofBridge.Transport,
                               maximumAge: Int64 = 30) async throws -> TOSV5R2InstalledWallet {
        try await observe(id: id, wallet: independentlyKnownWallet, anchor: locallyProvisionedAnchor, successor: nil,
                          initialize: initialize, primaryExecution: primaryExecution, transport: transport, maximumAge: maximumAge)
    }
    /// Observation of a locally authenticated successor, not migration/POP approval.
    public func observeSuccessor(id: UUID, independentlyKnownWallet: Address, locallyProvisionedAnchor: Data,
                                 successor: TOSV5R2Genesis, initialize: Bool, primaryExecution: Bool,
                                 transport: @escaping TOSV5R2ProofBridge.Transport, maximumAge: Int64 = 30) async throws -> TOSV5R2InstalledWallet {
        try await observe(id: id, wallet: independentlyKnownWallet, anchor: locallyProvisionedAnchor, successor: successor,
                          initialize: initialize, primaryExecution: primaryExecution, transport: transport, maximumAge: maximumAge)
    }
    private func observe(id: UUID, wallet: Address, anchor: Data, successor: TOSV5R2Genesis?, initialize: Bool,
                         primaryExecution: Bool, transport: @escaping TOSV5R2ProofBridge.Transport, maximumAge: Int64) async throws -> TOSV5R2InstalledWallet {
        let worker = try await proofCoordinator(id: id, wallet: wallet, anchor: anchor, successor: successor,
                                               transport: transport, maximumAge: maximumAge)
        return try await worker.observe(initialize: initialize, primaryExecution: primaryExecution)
    }
    /// Authenticated, proof-bound unsigned request. Does not sign, reserve a fee leaf or broadcast.
    public func preparePrimaryExecute(id: UUID, independentlyKnownWallet: Address, locallyProvisionedAnchor: Data,
                                      successor: TOSV5R2Genesis? = nil, initialize: Bool, actions: Cell, validUntil: UInt32,
                                      transport: @escaping TOSV5R2ProofBridge.Transport, maximumAge: Int64 = 30) async throws -> TOSV5R2Auth {
        try TOSV5R2Auth.validateActions(actions)
        guard TimeInterval(validUntil) > Date().timeIntervalSince1970 else { throw TOSPQError.invalidInput }
        let worker = try await proofCoordinator(id: id, wallet: independentlyKnownWallet, anchor: locallyProvisionedAnchor,
                                               successor: successor, transport: transport, maximumAge: maximumAge)
        return try await worker.preparePrimaryExecute(initialize: initialize, actions: actions, validUntil: validUntil)
    }
    private func proofCoordinator(id: UUID, wallet: Address, anchor: Data, successor: TOSV5R2Genesis?,
                                  transport: @escaping TOSV5R2ProofBridge.Transport, maximumAge: Int64) async throws -> TOSV5R2ProofCoordinator {
        guard (1...1_048_576).contains(anchor.count), (1...3599).contains(maximumAge) else { throw TOSPQError.invalidInput }
        try await unlock()
        guard let record = try list().first(where: { $0.id == id }), record.address == wallet else { throw TOSPQError.keyBinding }
        let birth = try TOSV5R2InitialRecovery.parseAndReconstruct(record.manifest, codes: codes, pins: pins, expectedWallet: wallet).genesis
        let worker = try TOSV5R2ProofCoordinator(id: id, anchor: anchor, birth: birth, successor: successor,
                                              transport: transport, maximumAge: maximumAge)
        return worker
    }

}
