import Foundation
import TKLogging

public final class WalletBackgroundUpdate {
    @Atomic public var eventClosure: ((BackgroundUpdateEvent) -> Void)?
    @Atomic public var stateClosure: ((BackgroundUpdateConnectionState) -> Void)?

    @Atomic public var state: BackgroundUpdateConnectionState = .connecting {
        didSet {
            logState(state: state)
            stateClosure?(state)
        }
    }

    // Serialize lifecycle changes with delivery. The recursive lock allows an
    // observer to stop updates from inside a state/event callback.
    private let lifecycleLock = NSRecursiveLock()
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private var cursor: TOSWalletTransactionCursor?
    private var requiresRefresh = true

    private let wallet: Wallet
    private let snapshot: () async throws -> TOSWalletTransactionCursor
    private let pollIntervalNanoseconds: UInt64

    init(
        wallet: Wallet,
        snapshot: @escaping () async throws -> TOSWalletTransactionCursor,
        pollIntervalNanoseconds: UInt64 = 3_000_000_000
    ) {
        precondition(pollIntervalNanoseconds > 0)
        self.wallet = wallet
        self.snapshot = snapshot
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    deinit {
        task?.cancel()
    }

    func start() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        task?.cancel()
        let generation = UUID()
        self.generation = generation
        requiresRefresh = true
        updateState(.connecting)
        // A callback may have stopped or restarted this updater.
        guard self.generation == generation else { return }

        let snapshot = self.snapshot
        let interval = pollIntervalNanoseconds
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let cursor = try await snapshot()
                    try Task.checkCancellation()
                    guard let self, self.received(cursor, generation: generation) else { return }
                } catch {
                    guard !Task.isCancelled, !error.isCancelledError else { return }
                    guard let self, self.received(error, generation: generation) else { return }
                }
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        generation = nil
        task?.cancel()
        task = nil
    }

    private func received(_ cursor: TOSWalletTransactionCursor, generation: UUID) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard self.generation == generation, !Task.isCancelled else { return false }
        let refresh = requiresRefresh || self.cursor != cursor
        self.cursor = cursor
        requiresRefresh = false
        updateState(.connected)
        guard self.generation == generation, !Task.isCancelled else { return false }
        if refresh {
            // Initial/resumed/recovered reads also refresh already-loaded History.
            eventClosure?(BackgroundUpdateEvent(wallet: wallet, lt: cursor.lt, txHash: cursor.txHash))
        }
        return self.generation == generation && !Task.isCancelled
    }

    private func received(_ error: Swift.Error, generation: UUID) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard self.generation == generation, !Task.isCancelled else { return false }
        requiresRefresh = true
        updateState(error.isNoConnectionError ? .noConnection : .disconnected)
        return self.generation == generation && !Task.isCancelled
    }

    private func updateState(_ state: BackgroundUpdateConnectionState) {
        guard self.state != state else { return }
        self.state = state
    }

    private func logState(state: BackgroundUpdateConnectionState) {
        switch state {
        case .connecting:
            Log.i("Log 🪵: WalletBackgroundUpdate - \(wallet.label) — connecting")
        case .connected:
            Log.i("Log 🪵: WalletBackgroundUpdate - \(wallet.label) — connected")
        case .disconnected:
            Log.i("Log 🪵: WalletBackgroundUpdate - \(wallet.label) — disconnected")
        case .noConnection:
            Log.i("Log 🪵: WalletBackgroundUpdate - \(wallet.label) — no connection")
        }
    }
}
