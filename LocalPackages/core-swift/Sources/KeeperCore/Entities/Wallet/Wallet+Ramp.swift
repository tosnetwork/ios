public extension Wallet {
    var isRampCashOrCryptoAvailable: Bool {
        guard network == .mainnet else {
            return false
        }

        switch kind {
        case .regular, .quantum, .signer, .ledger, .keystone:
            return true
        case .watchonly, .lockup:
            return false
        }
    }
}
