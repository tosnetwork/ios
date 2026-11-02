import Foundation
import CoreComponents

/// The dedicated two-step path: authorize local signing/estimation, then confirm
/// this exact quote for submission. RPC acceptance is always an unknown outcome.
public final class TOSQuantumPaymentCoordinator {
    public enum Error: Swift.Error { case missingEntry, binding, timedOut }
    private let outbox: TOSQuantumOutbox
    private let baseDirectory: URL?
    private let transport: (@escaping () -> Bool) throws -> TOSQuantumProofBridge.Transport
    private let signer: (TOSQuantumOutbox.Entry, UUID, TOSQuantumSeedKeychain.Context) throws -> Data
    private let broadcaster: (Data, @escaping () -> Bool) throws -> Void
    private let now: () -> Int64
    private static let permits = TOSQuantumAccountReader.Permits()

    public convenience init() throws {
        let custody = TOSQuantumSeedKeychain()
        try self.init(outbox: TOSQuantumOutbox(), transport: { cancelled in
            let endpoint = try Self.endpoint()
            let relay = try TOSQuantumProofHTTPTransport(endpoint: endpoint)
            return { try relay.query($0, maximumBytes: $1, isCancelled: cancelled) }
        }, signer: { entry, id, context in
            try custody.sign(id: id, role: entry.role, context: context, expectedPublicKey: entry.signingPublicKey,
                purpose: .selfPay, digest: entry.requestHash)
        }, broadcaster: { bytes, cancelled in
            let rpc = try TOSQuantumRPCTransport(endpoint: Self.endpoint())
            _ = try rpc.call(method: "sendBocReturnHash", params: ["boc": bytes.base64EncodedString()], isCancelled: cancelled)
        })
    }
    internal init(outbox: TOSQuantumOutbox, baseDirectory: URL? = nil,
                  transport: @escaping (@escaping () -> Bool) throws -> TOSQuantumProofBridge.Transport,
                  signer: @escaping (TOSQuantumOutbox.Entry, UUID, TOSQuantumSeedKeychain.Context) throws -> Data,
                  broadcaster: @escaping (Data, @escaping () -> Bool) throws -> Void,
                  now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.outbox = outbox; self.baseDirectory = baseDirectory; self.transport = transport
        self.signer = signer; self.broadcaster = broadcaster; self.now = now
    }
    private static func endpoint() throws -> URL {
        guard let value = TOSRPCSettings.quantumEndpoint, let url = TOSRPCSettings.jsonRPCEndpoint(for: value) else {
            throw TOSQuantumNetworkProfile.Error.missingEndpoint
        }
        return url
    }
    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private let deadline = DispatchTime.now() + 60
        func cancel() { lock.withLock { cancelled = true } }
        func isCancelled() -> Bool { lock.withLock { cancelled } || DispatchTime.now() >= deadline }
        func check() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
            if DispatchTime.now() >= deadline { throw Error.timedOut }
        }
        func failure(_ error: Swift.Error) -> Swift.Error {
            // Cancellation must not hide an uncertain durable write/checkpoint.
            if error is TOSQuantumOutbox.Error || error is TOSQuantumProofBridge.SimulationError { return error }
            if [NSCocoaErrorDomain, NSPOSIXErrorDomain].contains((error as NSError).domain) { return error }
            do { try check(); return error } catch { return error }
        }
    }
    private func perform<Value>(id: UUID, _ operation: @escaping (Job) throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        try Self.permits.enter(id)
        defer { Self.permits.leave(id) }
        let job = Job()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Swift.Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try job.check(); let value = try operation(job); try job.check()
                        continuation.resume(returning: value)
                    } catch { continuation.resume(throwing: job.failure(error)) }
                }
            }
        } onCancel: { job.cancel() }
        try Task.checkCancellation()
        return result
    }

    private func context(_ wallet: Wallet) throws -> (UUID, TOSQuantumSelfPayIdentity) {
        guard case .Quantum(let identity) = wallet.identity.kind, let id = UUID(uuidString: wallet.id),
              wallet.identity.networkGlobalId == identity.wallet.initialAuthority.globalID else { throw Error.binding }
        return (id, identity)
    }
    private func pending(id: UUID, identity: TOSQuantumSelfPayIdentity) throws -> TOSQuantumOutbox.Entry? {
        let record = try TOSQuantumCreationRecord.load(id: id, baseDirectory: baseDirectory)
        guard record.id == id, record.identity == identity else { throw Error.binding }
        let entry = try outbox.pending(identity: identity)
        guard entry == nil || entry?.profile == record.profile else { throw Error.binding }
        return entry
    }

    /// Background journal inspection for the App. An I/O error is not an empty slot.
    public func pending(wallet: Wallet) async throws -> TOSQuantumOutbox.Entry? {
        let (id, identity) = try context(wallet)
        return try await perform(id: id) { [self] _ in try pending(id: id, identity: identity) }
    }
    /// Only a reservation that never reached signing can be discarded by the user.
    public func cancelUnsigned(wallet: Wallet, operationID: UUID) async throws {
        let (id, identity) = try context(wallet)
        try await perform(id: id) { [self] job in
            guard let entry = try pending(id: id, identity: identity), entry.id == operationID else { throw Error.binding }
            try job.check(); try outbox.cancelUnsigned(entry)
        }
    }
    /// Explicit recovery estimate of the stored signature/BOC after restart.
    /// Fresh state must reproduce the original request, including its deadline.
    public func recoverAndEstimate(wallet: Wallet) async throws -> TOSQuantumPaymentQuote {
        let (id, identity) = try context(wallet)
        return try await perform(id: id) { [self] job in
            guard let entry = try pending(id: id, identity: identity), entry.phase == .signed, let bytes = entry.signedBOC else { throw Error.missingEntry }
            let relay = try transport({ job.isCancelled() })
            let accounts = TOSQuantumAccountReader(baseDirectory: baseDirectory, transport: {
                return { query, capacity in
                    try job.check(); let data = try relay(query, capacity); try job.check(); return data
                }
            }, now: now)
            let observation = try accounts.observeEnrolled(id: id, identity: identity, profile: entry.profile, configIndices: [8, 19, 48])
            let payment = try TOSQuantumPreparedPayment(recovering: entry, observation: observation, now: now())
            let session = try TOSQuantumProofSession(walletID: id, locallyProvisionedAnchor: entry.profile.anchor(), baseDirectory: baseDirectory)
            let simulation = try session.simulate(request: payment.simulationRequest(), now: now(), signedMessage: bytes) { query, capacity in
                try job.check(); let data = try relay(query, capacity); try job.check(); return data
            }
            let quote = try TOSQuantumPaymentQuote(payment: payment, entry: entry, simulation: simulation, now: now())
            guard let current = try pending(id: id, identity: identity) else { throw Error.missingEntry }
            try quote.requireSameEntry(current)
            return quote
        }
    }

    /// Call only after the user confirms the visible intent for local signing.
    /// Nothing broadcasts here. Any uncertainty after signing keeps the slot.
    public func authorizeAndEstimate(_ payment: TOSQuantumPreparedPayment) async throws -> TOSQuantumPaymentQuote {
        try await perform(id: payment.walletID) { [self] job in
            try payment.requireFresh(now: now())
            let record = try TOSQuantumCreationRecord.load(id: payment.walletID, baseDirectory: baseDirectory)
            guard record.identity == payment.identity, record.profile == payment.profile else { throw Error.binding }
            let context = try TOSQuantumSeedKeychain.Context(network: payment.identity.wallet.initialAuthority.namespace,
                globalID: payment.profile.globalID, account: record.account, generation: record.generation)
            let session = try TOSQuantumProofSession(walletID: payment.walletID,
                locallyProvisionedAnchor: payment.profile.anchor(), baseDirectory: baseDirectory)
            let relay = try transport({ job.isCancelled() })
            try job.check()
            let entry = try outbox.reserve(payment: payment, now: now())
            // Once signing can begin, cancellation must retain the authorization.
            try outbox.signReserved(entry) { stored in
                try job.check(); try payment.requireFresh(now: now())
                return try signer(stored, payment.walletID, context)
            }
            try job.check()
            guard let signed = try outbox.pending(identity: payment.identity), signed.id == entry.id,
                  let bytes = signed.signedBOC else { throw Error.missingEntry }
            let result = try session.simulate(request: payment.simulationRequest(), now: now(), signedMessage: bytes) { query, capacity in
                try job.check()
                let response = try relay(query, capacity)
                try job.check()
                return response
            }
            try job.check()
            return try TOSQuantumPaymentQuote(payment: payment, entry: signed, simulation: result, now: now())
        }
    }

    /// Call only for explicit confirmation of this displayed estimate. This
    /// never constructs another request or signature, even on timeout/retry.
    public func submit(_ quote: TOSQuantumPaymentQuote) async throws {
        try await perform(id: quote.payment.walletID) { [self] job in
            guard let entry = try outbox.pending(identity: quote.payment.identity) else { throw Error.missingEntry }
            try job.check()
            let bytes = try outbox.beginPaymentSubmission(entry, quote: quote, now: now())
            do {
                try job.check()
                // Lock waits and full fsync may outlive the time sampled before
                // durable publication. Recheck immediately before dispatch.
                try quote.requireFresh(entry: entry, now: now())
                try job.check()
                try broadcaster(bytes, { job.isCancelled() })
            } catch {
                // A transport error may follow acceptance; retain the exact BOC.
                try outbox.markUnknown(entry)
                try job.check()
                throw error
            }
            try outbox.markUnknown(entry)
        }
    }

    /// Explicit refresh of the same authorization, including after a lost RPC
    /// response. No request, deadline, signature or message bytes are replaced.
    /// A consumed/expired authorization requires receipt reconciliation instead.
    public func refresh(_ quote: TOSQuantumPaymentQuote) async throws -> TOSQuantumPaymentQuote {
        try await perform(id: quote.payment.walletID) { [self] job in
            try quote.payment.requireFresh(now: now())
            guard let entry = try outbox.pending(identity: quote.payment.identity),
                  let bytes = entry.signedBOC else { throw Error.missingEntry }
            try quote.requireSameEntry(entry)
            let session = try TOSQuantumProofSession(walletID: quote.payment.walletID,
                locallyProvisionedAnchor: quote.payment.profile.anchor(), baseDirectory: baseDirectory)
            let relay = try transport({ job.isCancelled() })
            let result = try session.simulate(request: quote.payment.simulationRequest(), now: now(), signedMessage: bytes) { query, capacity in
                try job.check()
                let response = try relay(query, capacity)
                try job.check()
                return response
            }
            try job.check()
            return try TOSQuantumPaymentQuote(payment: quote.payment, entry: entry, simulation: result, now: now())
        }
    }
}
