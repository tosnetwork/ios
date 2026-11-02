import Foundation
import BigInt
import TonSwift
import CoreComponents

/// The index discovers candidates; each returned amount comes from the enrolled proof reader.
/// A failed candidate does not replace a verified native balance with an empty wallet.
internal final class TOSQuantumTokenAssetsReader {
    struct Result {
        let native: TOSQuantumSelfPayAccount.Snapshot
        let tokens: [JettonBalance]
        let nodeReportsComplete: Bool
        let reachedRowLimit: Bool
        let unreadPositions: Int
        let unresolvedPrecision: Int
        let discoveryFailed: Bool
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        func stopped() -> Bool { lock.withLock { cancelled } }
        func check() throws { if stopped() { throw CancellationError() } }
    }
    private static let permits = TOSQuantumAccountReader.Permits()

    func read(wallet: Wallet) async throws -> Result {
        guard wallet.kind == .quantum, let id = UUID(uuidString: wallet.id),
              let endpoint = TOSRPCSettings.quantumEndpoint,
              let url = TOSRPCSettings.jsonRPCEndpoint(for: endpoint) else { throw TOSPQError.invalidInput }
        try Task.checkCancellation()
        try Self.permits.enter(id)
        defer { Self.permits.leave(id) }
        // Freeze discovery and all account proofs to the same user-selected endpoint.
        let proofHTTP = try TOSQuantumProofHTTPTransport(endpoint: url)
        let accounts = TOSQuantumAccountReader(transport: {
            { query, maximumBytes in try proofHTTP.query(query, maximumBytes: maximumBytes) }
        })
        let rpc = try TOSQuantumRPCTransport(endpoint: url, timeout: 10)
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            let owner = try await accounts.observe(wallet: wallet)
            try Task.checkCancellation()
            let result: Result = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try self.read(owner: owner, accounts: accounts, rpc: rpc, cancellation: cancellation)
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: { cancellation.cancel() }
    }

    private func read(owner: TOSQuantumAccountReader.Observation, accounts: TOSQuantumAccountReader,
                      rpc: TOSQuantumRPCTransport, cancellation: Cancellation) throws -> Result {
        try cancellation.check()
        let index: TOSQuantumTokenIndex
        do {
            let wire = try rpc.call(method: "getAccountTokens", params: ["address": owner.identity.address.toRaw(),
                "limit": TOSQuantumTokenIndex.maximumRows], isCancelled: cancellation.stopped)
            guard let object = wire as? [String: Any] else { throw TOSPQError.invalidInput }
            index = try TOSQuantumTokenIndex.decode(object)
        } catch {
            try cancellation.check()
            try owner.requireFresh(now: Int64(Date().timeIntervalSince1970))
            return Result(native: owner.snapshot, tokens: [], nodeReportsComplete: false, reachedRowLimit: false,
                          unreadPositions: 0, unresolvedPrecision: 0, discoveryFailed: true)
        }
        var tokens = [JettonBalance](), unread = 0, unresolved = 0
        let deadline = DispatchTime.now() + 30
        for (position, hint) in index.positions.enumerated() {
            try cancellation.check()
            if DispatchTime.now() >= deadline { unread += index.positions.count - position; break }
            let observed: TOSQuantumAccountReader.TokenObservation
            do {
                observed = try accounts.observeToken(owner: owner, master: Address.parse(hint.master), wallet: Address.parse(hint.wallet))
            } catch { try cancellation.check(); unread += 1; continue }
            guard let content = try? TOSTokenContent.decode(observed.masterState.content) else { unresolved += 1; continue }
            var remote: TOSTokenMetadata?
            if let uri = content.uri, content.name == nil || content.symbol == nil || content.decimals == nil {
                remote = try? TOSTokenMetadata.read(uri, isCancelled: cancellation.stopped)
                try cancellation.check()
            }
            guard let decimals = content.decimals ?? remote?.decimals else { unresolved += 1; continue }
            let info = JettonInfo(isTransferable: true, hasCustomPayload: false, address: observed.master,
                fractionDigits: decimals, name: content.name ?? remote?.name ?? "Token", symbol: content.symbol ?? remote?.symbol,
                verification: .none, imageURL: nil)
            tokens.append(JettonBalance(item: JettonItem(jettonInfo: info, walletAddress: observed.wallet),
                                        quantity: observed.balance, rates: [:]))
        }
        try cancellation.check()
        try owner.requireFresh(now: Int64(Date().timeIntervalSince1970))
        return Result(native: owner.snapshot, tokens: tokens, nodeReportsComplete: index.nodeReportsComplete,
                      reachedRowLimit: index.reachedRowLimit, unreadPositions: unread,
                      unresolvedPrecision: unresolved, discoveryFailed: false)
    }
}
