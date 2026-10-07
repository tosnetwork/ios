import Foundation
import TonSwift
import CoreComponents

/// One worker owns the immutable enrollment/transport. Only cancellation is shared,
/// protected by lock. The transport must enforce its own bounded receive and timeout.
internal final class TOSV5R2ProofCoordinator: @unchecked Sendable {
    private let id: UUID, anchor: Data, birth: TOSV5R2Genesis, successor: TOSV5R2Genesis?
    private let transport: TOSV5R2ProofBridge.Transport
    private let maximumAge: Int64, baseDirectory: URL?
    private let lock = NSLock()
    private var cancelled = false
    init(id: UUID, anchor: Data, birth: TOSV5R2Genesis, successor: TOSV5R2Genesis?,
         transport: @escaping TOSV5R2ProofBridge.Transport, maximumAge: Int64, baseDirectory: URL? = nil) throws {
        guard (1...1_048_576).contains(anchor.count), (1...3599).contains(maximumAge) else { throw TOSPQError.invalidInput }
        self.id = id; self.anchor = anchor; self.birth = birth; self.successor = successor
        self.transport = transport; self.maximumAge = maximumAge; self.baseDirectory = baseDirectory
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func checkCancellation() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
    }
    private func now() throws -> Int64 {
        try checkCancellation()
        let time = Int64(Date().timeIntervalSince1970)
        guard time > 0, time <= Int64(UInt32.max) else { throw TOSPQError.invalidInput }
        return time
    }
    private func address(_ value: Address) -> String { "0:" + value.hash.map { String(format: "%02x", $0) }.joined() }
    private func run(initialize: Bool, primaryExecution: Bool) throws -> TOSV5R2InstalledWallet {
        let route = try successor.map { try TOSV5R2InstalledRoute.successor(birth: birth, next: $0) } ?? .initial(birth)
        try checkCancellation()
        let session = try TOSV5R2ProofSession(walletID: id, locallyProvisionedAnchor: anchor, baseDirectory: baseDirectory)
        let bounded: TOSV5R2ProofBridge.Transport = { [self] query, capacity in
            try checkCancellation()
            let response = try transport(query, capacity)
            try checkCancellation()
            return response
        }
        let request = try JSONSerialization.data(withJSONObject: ["mode": "live", "max_age_seconds": maximumAge, "account": address(birth.address)])
        let wallet = try initialize ? session.enrollBound(request: request, now: now(), transport: bounded)
                                    : session.readBound(request: request, now: now(), transport: bounded)
        let module = try session.readBound(request: wallet.requestAtCheckpoint(account: address(route.moduleAddress), maximumAge: maximumAge), now: now(), transport: bounded)
        let vault = try session.readBound(request: wallet.requestAtCheckpoint(account: address(route.vaultAddress), maximumAge: maximumAge), now: now(), transport: bounded)
        let installed: TOSV5R2InstalledWallet
        if let successor {
            installed = try .bindSuccessor(birth: birth, next: successor, wallet: wallet, module: module, vault: vault, now: now(), maximumAge: maximumAge)
        } else {
            installed = try .bindInitial(birth: birth, wallet: wallet, module: module, vault: vault, now: now(), maximumAge: maximumAge)
        }
        if primaryExecution {
            let policy = try session.readBound(request: wallet.requestAtCheckpoint(configIndices: [48], maximumAge: maximumAge), now: now(), transport: bounded)
            try installed.requirePrimaryExecution(policyProof: policy, now: now(), maximumAge: maximumAge)
        }
        try installed.requireFeeProof(now: now(), maximumAge: maximumAge)
        try checkCancellation()
        return installed
    }
    func observe(initialize: Bool, primaryExecution: Bool) async throws -> TOSV5R2InstalledWallet {
        try Task.checkCancellation()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TOSV5R2InstalledWallet, Error>) in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do { continuation.resume(returning: try run(initialize: initialize, primaryExecution: primaryExecution)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
        try Task.checkCancellation()
        return result
    }
}
