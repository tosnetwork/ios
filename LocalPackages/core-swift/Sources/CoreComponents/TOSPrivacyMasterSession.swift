import Foundation

/// A short-lived, bound TOS mnemonic master. It exposes only privacy operations,
/// never plaintext master/role seeds. Swift copies cannot promise forensic erasure.
public final class TOSPrivacyMasterSession {
    public enum Failure: Error { case materialUnavailable, binding }
    public struct Binding: Equatable {
        public let globalID: Int32
        public let namespace: Data
        public let birthHash: Data
        public let birthPrimaryKey: Data
        public init(globalID: Int32, namespace: Data, birthHash: Data, birthPrimaryKey: Data) throws {
            guard namespace.count == 32, birthHash.count == 32,
                  birthPrimaryKey.count == TOSQuantumRole.primary.publicKeySize else { throw Failure.binding }
            self.globalID = globalID; self.namespace = namespace
            self.birthHash = birthHash; self.birthPrimaryKey = birthPrimaryKey
        }
    }
    private let binding: Binding
    private let lock = NSLock()
    private var master: Data?

    /// Uses the original primary root at account/generation 0/0, not current
    /// authority after a rotation. A raw role seed is not a master input API.
    public static func mnemonic(words: [String], phrasePassword: inout Data,
                                binding: Binding) throws -> TOSPrivacyMasterSession {
        defer { phrasePassword.resetBytes(in: 0..<phrasePassword.count) }
        guard !Thread.isMainThread else { throw TOSPrivacyNative.Failure.requiresWorker }
        var master = try TOSQuantumMnemonic.masterAndWipePassword(words: words, password: &phrasePassword)
        defer { master.resetBytes(in: 0..<master.count) }
        return try boundMasterAndWipe(&master, binding: binding)
    }
    /// Only the validated recovery-payload adapter in this module supplies raw masters.
    internal static func boundMasterAndWipe(_ master: inout Data, binding: Binding) throws -> TOSPrivacyMasterSession {
        defer { master.resetBytes(in: 0..<master.count) }
        guard !Thread.isMainThread else { throw TOSPrivacyNative.Failure.requiresWorker }
        guard master.count == 32 else { throw Failure.materialUnavailable }
        var copy = master
        var primary = try TOSQuantumKdf.deriveAndWipe(material: .primary, master: &copy,
            network: binding.namespace, globalID: binding.globalID, account: 0, generation: 0)
        defer { copy.resetBytes(in: 0..<copy.count); primary.resetBytes(in: 0..<primary.count) }
        guard try TOSQuantumSigner.publicKey(role: .primary, seed: primary) == binding.birthPrimaryKey else {
            throw Failure.materialUnavailable
        }
        return TOSPrivacyMasterSession(master: master, binding: binding)
    }
    private init(master: Data, binding: Binding) { self.master = master; self.binding = binding }
    deinit { close() }
    public func close() {
        lock.lock(); defer { lock.unlock() }
        discardMaster()
    }
    private func discardMaster() {
        let count = master?.count ?? 0
        master?.resetBytes(in: 0..<count); master = nil
    }
    /// One-shot worker operation. The caller proves the pool separately, and must
    /// recheck that original observation on both sides of native scanning.
    public func summaryAndClose(history: TOSPrivacyHistoryWalk.Completed, binding: Binding,
                                stopped: () -> Bool, recheck: () throws -> Void) throws -> Data {
        try withSeedAndClose(binding: binding) { seed in
            try history.summaryAndWipeSeed(seed: &seed, stopped: stopped, recheck: recheck)
        }
    }

    public func receiveAndClose(history: TOSPrivacyHistoryWalk.Completed, binding: Binding,
                                root: Data, poolBinding: Data, requireCurrent: () throws -> Void) throws -> Data {
        try withSeedAndClose(binding: binding) { seed in
            try history.receiveAndWipeSeed(seed: &seed, root: root, binding: poolBinding,
                                          requireCurrent: requireCurrent)
        }
    }

    private func withSeedAndClose(binding: Binding, operation: (inout Data) throws -> Data) throws -> Data {
        guard !Thread.isMainThread else { close(); throw TOSPrivacyNative.Failure.requiresWorker }
        lock.lock(); defer { lock.unlock() }
        defer { discardMaster() }
        guard self.binding == binding else { throw Failure.binding }
        guard var seed = master else { throw Failure.materialUnavailable }
        defer { seed.resetBytes(in: 0..<seed.count) }
        return try operation(&seed)
    }
}
