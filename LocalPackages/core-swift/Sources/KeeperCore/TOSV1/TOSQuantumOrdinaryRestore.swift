import Foundation

/// Public-state policy only. Callers authenticate the network, account and freshness first.
/// This neither revokes another device nor reconstructs its missing pending-operation journal.
internal enum TOSQuantumOrdinaryRestore {
    enum Error: LocalizedError {
        case frozen, authorityMismatch, counterExhausted, existingRecovery

        var errorDescription: String? {
            switch self {
            case .frozen: return "Frozen wallet requires a separate recovery flow."
            case .authorityMismatch: return "Current wallet authority differs from this ordinary backup; use the recovery flow."
            case .counterExhausted: return "Wallet execute counter exhausted."
            case .existingRecovery: return "An existing recovery operation must be completed; its saved state cannot be replaced."
            }
        }
    }

    static func requireUsable(identity: TOSQuantumSelfPayIdentity, status: TOSQuantumSelfPayAccount.Status) throws {
        switch status {
        case .absent, .uninitialized: return
        case .frozen: throw Error.frozen
        case .active(let state):
            guard state.walletID == identity.wallet.walletID, state.retired == 0,
                  state.authority.hash == identity.wallet.initialAuthority.hash else { throw Error.authorityMismatch }
            guard state.seqno < UInt32.max, state.primaryNonce < UInt64.max else { throw Error.counterExhausted }
        }
    }
}
