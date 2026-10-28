import Foundation
import CoreComponents

/// User-requested local retirement only. This service never creates a payment,
/// accesses custody, signs or broadcasts. Stored history remains local metadata.
public final class TOSQuantumRetirementCoordinator {
    public enum Error: Swift.Error { case noAuthorization, binding }
    public enum Mode { case verifySenderOutcome, explicitlyUnverified }
    public enum State {
        case none
        case authorization(TOSQuantumOutbox.Entry, recovering: Bool)
        case completed(TOSQuantumRetirementSummary)
    }
    /// Native proof capabilities stay private to the service's explicit review.
    /// A local summary cannot reconstruct one of these objects after restart.
    public final class Review {
        public let entry: TOSQuantumOutbox.Entry
        public let deadline: UInt32
        public let provenShardTime: UInt32
        public let outcome: TOSQuantumRetirementSummary.Outcome
        fileprivate let walletID: UUID
        fileprivate let source: TOSQuantumOutbox.RetirementSource
        fileprivate let expiry: TOSQuantumExpiredAuthorization
        fileprivate let receipt: TOSQuantumPaymentOutcomeReader.Receipt?
        fileprivate init(id: UUID, source: TOSQuantumOutbox.RetirementSource, expiry: TOSQuantumExpiredAuthorization,
                         receipt: TOSQuantumPaymentOutcomeReader.Receipt?) throws {
            walletID = id; self.source = source; self.expiry = expiry; self.receipt = receipt
            entry = source.entry; deadline = try TOSQuantumStoredRequest(entry: source.entry).deadline
            provenShardTime = expiry.provenShardTime
            outcome = receipt.map { $0.outcome == .senderSent ? .senderSent : .includedWithoutExactTransfer } ?? .expiredUnverified
        }
    }
    private let outbox: TOSQuantumOutbox
    private let baseDirectory: URL?
    private let expiryReader: TOSQuantumAuthorizationExpiryReader
    private let outcomeReader: TOSQuantumPaymentOutcomeReader
    private let now: () -> Int64
    private static let ioPermits = TOSQuantumAccountReader.Permits()

    public convenience init() throws {
        try self.init(outbox: TOSQuantumOutbox(), baseDirectory: nil, expiry: nil, outcomes: nil)
    }
    internal init(outbox: TOSQuantumOutbox, baseDirectory: URL?,
                  expiry: TOSQuantumAuthorizationExpiryReader?, outcomes: TOSQuantumPaymentOutcomeReader?,
                  now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) throws {
        self.outbox = outbox; self.baseDirectory = baseDirectory; self.now = now
        if let expiry { expiryReader = expiry } else { expiryReader = try TOSQuantumAuthorizationExpiryReader() }
        if let outcomes { outcomeReader = outcomes } else { outcomeReader = try TOSQuantumPaymentOutcomeReader() }
    }
    private func context(_ wallet: Wallet) throws -> (UUID, TOSQuantumSelfPayIdentity, TOSQuantumNetworkProfile) {
        guard case .Quantum(let identity) = wallet.identity.kind, let id = UUID(uuidString: wallet.id),
              wallet.identity.networkGlobalId == identity.wallet.initialAuthority.globalID else { throw Error.binding }
        let record = try TOSQuantumCreationRecord.load(id: id, baseDirectory: baseDirectory)
        guard record.id == id, record.identity == identity else { throw Error.binding }
        return (id, identity, record.profile)
    }
    private func perform<T>(id: UUID, _ work: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation(); try Self.ioPermits.enter(id)
        defer { Self.ioPermits.leave(id) }
        let result: T = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation(); return result
    }
    public func inspect(wallet: Wallet) async throws -> State {
        guard let id = UUID(uuidString: wallet.id) else { throw Error.binding }
        return try await perform(id: id) { [self] in
            let (_, identity, profile) = try context(wallet)
            switch try outbox.inspectRetirement(identity: identity, profile: profile) {
            case .none: return .none
            case .authorization(let source, let recovering): return .authorization(source.entry, recovering: recovering)
            case .completed(let summary): return .completed(summary)
            }
        }
    }
    /// The caller must explicitly choose this operation; an unverified mode is
    /// not a fallback for a failed proof or a claim that the payment never happened.
    public func review(wallet: Wallet, operationID: UUID, mode: Mode = .verifySenderOutcome) async throws -> Review {
        guard let id = UUID(uuidString: wallet.id) else { throw Error.binding }
        let source: TOSQuantumOutbox.RetirementSource = try await perform(id: id) { [self] in
            let (_, identity, profile) = try context(wallet)
            guard case .authorization(let source, _) = try outbox.inspectRetirement(identity: identity, profile: profile, operationID: operationID) else {
                throw Error.noAuthorization
            }
            return source
        }
        var receipt: TOSQuantumPaymentOutcomeReader.Receipt?
        if mode == .verifySenderOutcome, source.entry.paymentIntent != nil, source.entry.signedBOC != nil {
            receipt = try await outcomeReader.read(wallet: wallet, source: source).receipt
        }
        try Task.checkCancellation()
        // Expiry comes last, after history's checkpoint can advance. Its freshness
        // is sampled again inside the lock immediately before canonical unlink.
        let expiry = try await expiryReader.read(wallet: wallet, source: source)
        try Task.checkCancellation()
        return try Review(id: id, source: source, expiry: expiry, receipt: receipt)
    }
    /// Explicit user confirmation of the displayed retirement result, independent
    /// from the original 30-second payment quote. Nothing automatically starts next.
    public func complete(_ review: Review) async throws -> TOSQuantumRetirementSummary {
        try await perform(id: review.walletID) { [self] in
            try outbox.finishRetirement(review.source, expiry: review.expiry, receipt: review.receipt, now: now)
        }
    }
    public func localHistory(wallet: Wallet) async throws -> [TOSQuantumRetirementSummary] {
        guard let id = UUID(uuidString: wallet.id) else { throw Error.binding }
        return try await perform(id: id) { [self] in
            let (_, identity, profile) = try context(wallet)
            return try outbox.retirementHistory(identity: identity, profile: profile)
        }
    }
}
