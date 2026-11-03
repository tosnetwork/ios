import Darwin
import Foundation
import Security
import CoreComponents

/// Read-only user service. No signing, descriptor allocation, local-note store,
/// submission or retry is added here. An observation is not a pending-adjusted balance.
public final class TOSPrivacyWalletService {
    public enum Failure: Error { case unsupportedWallet, materialUnavailable, authentication, binding, busy, stopped }
    public enum Access: Equatable { case appPasscode, devicePresence }
    public enum Authorization { case appPasscode(String), devicePresence }
    public struct Preparation {
        public let profile: TOSQuantumNetworkProfile
        public let access: Access
    }
    public struct Observed: Equatable {
        public let walletID: UUID
        public let profile: TOSQuantumNetworkProfile
        public let poolAddress: String
        public let summary: TOSPrivacySummary
        public let provenShardTime: UInt32
        public let observedAt: Int64
    }
    private struct Context {
        let id: UUID
        let identity: TOSQuantumSelfPayIdentity
        let profile: TOSQuantumNetworkProfile
        let recovery: TOSQuantumOutbox.RecoveryRecord?
        var binding: TOSPrivacyMasterSession.Binding {
            get throws {
                try TOSPrivacyMasterSession.Binding(globalID: profile.globalID,
                    namespace: identity.wallet.initialAuthority.namespace,
                    birthHash: identity.cell.hash(), birthPrimaryKey: identity.wallet.initialAuthority.primaryKey)
            }
        }
        func requireSame(_ other: Context) throws {
            guard id == other.id, identity == other.identity, profile == other.profile,
                  recovery == other.recovery else { throw Failure.binding }
        }
    }
    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private let deadline = DispatchTime.now() + 600
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func stopped() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled || DispatchTime.now() >= deadline
        }
        func check() throws { if stopped() { throw Failure.stopped } }
    }
    private static let permitLock = NSLock()
    private static var active = Set<Data>()
    private let mnemonics: MnemonicsRepository
    private let baseDirectory: URL?
    private let outboxDirectory: URL?
    private let privacyStoreParent: URL?
    private let now: () -> Int64

    public convenience init(mnemonics: MnemonicsRepository) {
        self.init(mnemonics: mnemonics, baseDirectory: nil, outboxDirectory: nil,
                  now: { Int64(Date().timeIntervalSince1970) })
    }
    internal init(mnemonics: MnemonicsRepository, baseDirectory: URL?, outboxDirectory: URL?, privacyStoreParent: URL? = nil, now: @escaping () -> Int64) {
        self.mnemonics = mnemonics; self.baseDirectory = baseDirectory; self.outboxDirectory = outboxDirectory; self.privacyStoreParent = privacyStoreParent; self.now = now
    }
    private func context(_ wallet: Wallet) throws -> Context {
        guard case .Quantum(let identity) = wallet.identity.kind, let id = UUID(uuidString: wallet.id),
              wallet.identity.networkGlobalId == identity.wallet.initialAuthority.globalID else { throw Failure.unsupportedWallet }
        // Ordinary provenance wins even if a recovery sidecar also exists. Missing
        // vault entries, bad passwords and corrupt records never switch routes.
        if let record = try TOSQuantumCreationRecord.loadIfPresent(id: id, baseDirectory: baseDirectory) {
            guard record.id == id, record.identity == identity else { throw Failure.binding }
            return Context(id: id, identity: identity, profile: record.profile, recovery: nil)
        }
        let outbox = try TOSQuantumOutbox(baseDirectory: outboxDirectory)
        let recovery = try outbox.recoveryRecord(identity, id: id)
        return Context(id: id, identity: identity, profile: recovery.profile, recovery: recovery)
    }
    private func worker<Value>(_ job: Job, _ operation: @escaping () throws -> Value) async throws -> Value {
        try job.check(); try Task.checkCancellation()
        let result: Value = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try job.check(); let value = try operation(); try job.check(); continuation.resume(returning: value) }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation(); return result
    }
    public func prepare(wallet: Wallet) async throws -> Preparation {
        let job = Job()
        return try await withTaskCancellationHandler {
            try await worker(job) {
                let context = try self.context(wallet)
                return Preparation(profile: context.profile, access: context.recovery == nil ? .appPasscode : .devicePresence)
            }
        } onCancel: { job.cancel() }
    }
    public func read(wallet: Wallet, authorization: Authorization, selection: TOSPrivacyPoolSelection) async throws -> Observed {
        try await withVerifiedWallet(wallet: wallet, authorization: authorization, selection: selection,
                                     forReceive: false) { completed, master, context, observation, job in
            let bytes = try completed.summaryAndCloseMaster(master, binding: context.binding,
                stopped: job.stopped, now: self.now)
            let summary = try TOSPrivacySummary(nativeJSON: bytes)
            let time = try observation.provenShardTime(now: self.now())
            return Observed(walletID: context.id, profile: context.profile, poolAddress: selection.address.toRaw(),
                summary: summary, provenShardTime: time, observedAt: self.now())
        }
    }

    public func validateRecipient(wallet: Wallet, authorization: Authorization,
                                  selection: TOSPrivacyPoolSelection, input: String) async throws -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count == 3432, let descriptor = Data(base64Encoded: text),
              descriptor.count == 2573, descriptor.base64EncodedString() == text else { return false }
        return try await withVerifiedWallet(wallet: wallet, authorization: authorization, selection: selection,
                                            forReceive: false) { completed, _, _, _, job in
            try job.check()
            return try completed.validateRecipient(descriptor, now: self.now)
        }
    }

    public func receive(wallet: Wallet, authorization: Authorization, selection: TOSPrivacyPoolSelection) async throws -> Data {
        try await withVerifiedWallet(wallet: wallet, authorization: authorization, selection: selection,
                                     forReceive: true) { completed, master, context, _, job in
            let root = try self.privacyStoreRoot()
            return try completed.receiveAndCloseMaster(master, binding: context.binding,
                root: Data(root.path.utf8), stopped: job.stopped, now: self.now)
        }
    }

    public func requestRelayOffer(
        wallet: Wallet, authorization: Authorization, selection: TOSPrivacyPoolSelection, approvedRelay: Data
    ) async throws -> TOSPrivacyNative.RelayOffer {
        try await withVerifiedWallet(wallet: wallet, authorization: authorization, selection: selection,
                                     forReceive: true) { completed, _, _, _, job in
            try job.check()
            return try completed.requestRelayOffer(approvedRelay, now: self.now)
        }
    }

    public func loadPaymentProver(
        wallet: Wallet, authorization: Authorization, selection: TOSPrivacyPoolSelection,
        phase1: URL, ceremony: URL
    ) async throws -> TOSPrivacyNative.PaymentProver {
        try await withVerifiedWallet(wallet: wallet, authorization: authorization, selection: selection,
                                     forReceive: true) { completed, _, _, _, job in
            try job.check()
            return try completed.loadPaymentProver(phase1: phase1, ceremony: ceremony, now: self.now)
        }
    }

    public func stagePayment(
        wallet: Wallet, authorization: Authorization, selection: TOSPrivacyPoolSelection,
        recipient: Data, amount: String, fee: String, quoteIdentity: String,
        prover: TOSPrivacyNative.PaymentProver, offer: TOSPrivacyNative.RelayOffer
    ) async throws -> TOSPrivacyNative.PaymentSubmission {
        try await withVerifiedWallet(wallet: wallet, authorization: authorization, selection: selection,
                                     forReceive: true) { completed, master, context, _, job in
            let root = try self.privacyStoreRoot()
            try job.check()
            return try completed.stagePaymentAndCloseMaster(master, binding: context.binding, root: root,
                recipient: recipient, amount: amount, fee: fee, quoteIdentity: quoteIdentity,
                prover: prover, offer: offer, now: self.now)
        }
    }

    public func recoverPayment(
        wallet: Wallet, authorization: Authorization, selection: TOSPrivacyPoolSelection, approvedRelay: Data
    ) async throws -> TOSPrivacyNative.PaymentSubmission? {
        try await withVerifiedWallet(wallet: wallet, authorization: authorization, selection: selection,
                                     forReceive: true) { completed, master, context, _, job in
            guard var fields = try JSONSerialization.jsonObject(with: approvedRelay) as? [String: Any] else {
                throw Failure.binding
            }
            fields["root"] = try self.privacyStoreRoot().path
            let request = try JSONSerialization.data(withJSONObject: fields)
            try job.check()
            return try completed.recoverPaymentAndCloseMaster(master, binding: context.binding,
                request: request, now: self.now)
        }
    }

    private func privacyStoreRoot() throws -> URL {
        let parent = try privacyStoreParent ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        var root = parent.appendingPathComponent("tos-privacy", isDirectory: true)
        if mkdir(root.path, 0o700) != 0 && errno != EEXIST { throw POSIXError(.EIO) }
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        return root
    }

    private func withVerifiedWallet<Value>(
        wallet: Wallet, authorization: Authorization, selection: TOSPrivacyPoolSelection, forReceive: Bool,
        operation: @escaping (TOSPrivacyHistorySynchronizer.Completed, TOSPrivacyMasterSession,
                              Context, TOSQuantumAccountReader.PoolObservation, Job) throws -> Value
    ) async throws -> Value {
        guard case .Quantum(let identity) = wallet.identity.kind else { throw Failure.unsupportedWallet }
        try Task.checkCancellation()
        let birth = identity.cell.hash()
        try Self.permitLock.withLock {
            guard Self.active.count < 2, !Self.active.contains(birth) else { throw Failure.busy }
            Self.active.insert(birth)
        }
        defer { Self.permitLock.withLock { _ = Self.active.remove(birth) } }
        let job = Job()
        do { return try await withTaskCancellationHandler {
            let context = try await worker(job) { try self.context(wallet) }
            guard context.profile == selection.profile else { throw Failure.binding }
            try job.check(); try Task.checkCancellation()
            let master: TOSPrivacyMasterSession
            switch (context.recovery, authorization) {
            case (.some(let recovery), .devicePresence):
                master = try await worker(job) {
                    let session: TOSQuantumBackupInspectionSession
                    do {
                        session = try TOSQuantumBackupInspectionSession.openProtected(id: context.id,
                            birthHash: context.identity.cell.hash(), originalDigest: recovery.encryptedDigest)
                    } catch TOSPQError.keychain(let status) where status == errSecItemNotFound {
                        throw Failure.materialUnavailable
                    }
                    defer { session.close() }
                    let file = try TOSQuantumBackupFileIdentity(fields: session.identity, profile: context.profile,
                        expectedNamespace: context.identity.wallet.initialAuthority.namespace)
                    guard file.birth == context.identity else { throw Failure.binding }
                    _ = try session.validateSecrets(primary: file.snapshot.primaryKey, rescue: file.snapshot.rescueKey)
                    return try session.privacyMaster(binding: context.binding)
                }
            case (nil, .appPasscode(let password)):
                guard await mnemonics.checkIfPasswordValid(password) else { throw Failure.authentication }
                let mnemonic: CoreComponents.Mnemonic
                do { mnemonic = try await mnemonics.getMnemonic(wallet: wallet, password: password) }
                catch RNMnemonicsVault.Error.noMnemonic { throw Failure.materialUnavailable }
                catch MnemonicsVault.Error.noMnemonic { throw Failure.materialUnavailable }
                try job.check(); try Task.checkCancellation()
                master = try await worker(job) {
                    var phrasePassword = Data()
                    return try TOSPrivacyMasterSession.mnemonic(words: mnemonic.mnemonicWords,
                        phrasePassword: &phrasePassword, binding: context.binding)
                }
            default:
                throw Failure.binding
            }
            defer { master.close() }
            do {
                return try await worker(job) {
                    guard let endpoint = TOSRPCSettings.quantumEndpoint,
                          let url = TOSRPCSettings.jsonRPCEndpoint(for: endpoint) else { throw TOSQuantumNetworkProfile.Error.missingEndpoint }
                    let reader = TOSQuantumAccountReader(baseDirectory: self.baseDirectory, transport: {
                        let relay = try TOSQuantumProofHTTPTransport(endpoint: url)
                        return { try relay.query($0, maximumBytes: $1, isCancelled: job.stopped) }
                    }, now: self.now)
                    let observation = try reader.observePool(id: context.id, identity: context.identity, profile: context.profile,
                        address: selection.address, expectedCode: selection.code, profileHash: selection.profileHash,
                        manifestHash: selection.manifestHash, verifyingKeyHash: selection.verifyingKeyHash)
                    try job.check()
                    let completed = try TOSPrivacyHistorySynchronizer.synchronize(observation: observation,
                        endpoint: url, stopped: job.stopped, now: self.now, forReceive: forReceive)
                    defer { completed.close() }
                    let result = try operation(completed, master, context, observation, job)
                    try context.requireSame(self.context(wallet)); try job.check()
                    return result
                }
            } catch TOSPrivacyMasterSession.Failure.materialUnavailable { throw Failure.materialUnavailable }
        } onCancel: { job.cancel() }
        } catch TOSPrivacyMasterSession.Failure.materialUnavailable { throw Failure.materialUnavailable }
    }
}
