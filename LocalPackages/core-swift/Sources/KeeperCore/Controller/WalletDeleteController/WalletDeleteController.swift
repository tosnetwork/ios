import Foundation
import CoreComponents

public final class WalletDeleteController {
    private let walletStore: WalletsStore
    private let keeperInfoStore: KeeperInfoStore
    private let mnemonicsRepository: MnemonicsRepository
    private let removeQuantumRole: (UUID, TOSQuantumRole) throws -> Void
    private let removeAllQuantumRoles: () throws -> Void

    init(
        walletStore: WalletsStore,
        keeperInfoStore: KeeperInfoStore,
        mnemonicsRepository: MnemonicsRepository,
        removeQuantumRole: @escaping (UUID, TOSQuantumRole) throws -> Void = {
            try TOSQuantumSeedKeychain().delete(id: $0, role: $1)
        },
        removeAllQuantumRoles: @escaping () throws -> Void = { try TOSQuantumSeedKeychain().deleteAll() }
    ) {
        self.walletStore = walletStore
        self.keeperInfoStore = keeperInfoStore
        self.mnemonicsRepository = mnemonicsRepository
        self.removeQuantumRole = removeQuantumRole
        self.removeAllQuantumRoles = removeAllQuantumRoles
    }

    public func deleteWallet(wallet: Wallet, passcode: String) async throws {
        if wallet.kind == .quantum {
            guard await mnemonicsRepository.checkIfPasswordValid(passcode), let id = UUID(uuidString: wallet.id) else {
                throw TOSPQError.keyBinding
            }
            try removeQuantumRole(id, .primary)
            try removeQuantumRole(id, .rescue)
        }
        try await mnemonicsRepository.deleteMnemonic(wallet: wallet, password: passcode)
        await walletStore.deleteWallet(wallet)
    }

    public func deleteWallet(wallet: Wallet) async throws {
        guard wallet.kind != .quantum else { throw TOSPQError.keyBinding }
        await walletStore.deleteWallet(wallet)
    }

    public func deleteAll() async throws {
        try removeAllQuantumRoles()
        if mnemonicsRepository.hasMnemonics() {
            try await mnemonicsRepository.deleteAll()
        }
        await walletStore.deleteAllWallets()
    }
}
