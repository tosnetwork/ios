import Foundation
import CoreComponents

public final class WalletDeleteController {
    private let walletStore: WalletsStore
    private let keeperInfoStore: KeeperInfoStore
    private let mnemonicsRepository: MnemonicsRepository
    private let removeQuantumRole: (UUID, TOSQuantumRole) throws -> Void
    private let removeAllQuantumRoles: () throws -> Void
    private let removeQuantumEnrollment: (UUID) throws -> Void
    private let removeAllQuantumEnrollments: () throws -> Void

    init(
        walletStore: WalletsStore,
        keeperInfoStore: KeeperInfoStore,
        mnemonicsRepository: MnemonicsRepository,
        removeQuantumRole: @escaping (UUID, TOSQuantumRole) throws -> Void = {
            try TOSQuantumSeedKeychain().delete(id: $0, role: $1)
        },
        removeAllQuantumRoles: @escaping () throws -> Void = { try TOSQuantumSeedKeychain().deleteAll() },
        removeQuantumEnrollment: @escaping (UUID) throws -> Void = {
            try TOSQuantumCreationRecord.remove(id: $0)
            try TOSQuantumProofSession.removeCheckpoint(walletID: $0)
        },
        removeAllQuantumEnrollments: @escaping () throws -> Void = {
            try TOSQuantumCreationRecord.removeAll()
            try TOSQuantumProofSession.removeAllCheckpoints()
        }
    ) {
        self.walletStore = walletStore
        self.keeperInfoStore = keeperInfoStore
        self.mnemonicsRepository = mnemonicsRepository
        self.removeQuantumRole = removeQuantumRole
        self.removeAllQuantumRoles = removeAllQuantumRoles
        self.removeQuantumEnrollment = removeQuantumEnrollment
        self.removeAllQuantumEnrollments = removeAllQuantumEnrollments
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
        if wallet.kind == .quantum {
            try await walletStore.deleteWalletDurably(wallet)
            if let id = UUID(uuidString: wallet.id) { try removeQuantumEnrollment(id) }
        } else { await walletStore.deleteWallet(wallet) }
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
        try await walletStore.deleteAllWalletsDurably()
        try removeAllQuantumEnrollments()
    }
}
