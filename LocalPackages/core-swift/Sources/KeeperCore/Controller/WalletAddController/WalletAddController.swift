import CoreComponents
import Foundation
import TonSwift
import TonTransport
import TronSwift

public final class WalletAddController {
    private let walletsStore: WalletsStore
    private let tonProofTokenService: TonProofTokenService
    private let mnemonicsRepository: MnemonicsRepository
    private let tronBalanceService: TronBalanceService
    private let enrollmentDirectory: URL?
    private let removeEnrollmentCheckpoint: (UUID) throws -> Void
    private let removeEnrollmentRole: (UUID, TOSQuantumRole) throws -> Void
    private let networkIdentityProvider: (Network) async throws -> Int32

    init(
        walletsStore: WalletsStore,
        tonProofTokenService: TonProofTokenService,
        mnemonicsRepositoty: MnemonicsRepository,
        tronBalanceService: TronBalanceService,
        networkIdentityProvider: @escaping (Network) async throws -> Int32,
        enrollmentDirectory: URL? = nil,
        removeEnrollmentRole: @escaping (UUID, TOSQuantumRole) throws -> Void = { try TOSQuantumSeedKeychain().delete(id: $0, role: $1) },
        removeEnrollmentCheckpoint: @escaping (UUID) throws -> Void = { try TOSQuantumProofSession.removeCheckpoint(walletID: $0) }
    ) {
        self.walletsStore = walletsStore
        self.tonProofTokenService = tonProofTokenService
        self.mnemonicsRepository = mnemonicsRepositoty
        self.tronBalanceService = tronBalanceService
        self.networkIdentityProvider = networkIdentityProvider
        self.enrollmentDirectory = enrollmentDirectory
        self.removeEnrollmentRole = removeEnrollmentRole
        self.removeEnrollmentCheckpoint = removeEnrollmentCheckpoint
    }

    public func createWallet(
        metaData: WalletMetaData,
        passcode: String,
        mnemonicWords: [String],
        quantumProfile: TOSQuantumNetworkProfile? = nil,
        setupSettings: WalletSetupSettings = WalletSetupSettings(),
        onEnrollment: (UUID) -> Void = { _ in }
    ) async throws {
        guard setupSettings.backupDate != nil else { throw TOSPQError.invalidInput }
        let mnemonicWords = TOSV1MnemonicValidator.normalize(mnemonicWords)
        guard TOSMnemonic.isValid(mnemonicWords) else { throw Mnemonic.Error.incorrectMnemonicWords }
        let mnemonic = try Mnemonic(mnemonicWords: mnemonicWords)
        let profile = try quantumProfile ?? TOSQuantumNetworkProfile.effective()
        func wallet(_ record: TOSQuantumCreationRecord) -> Wallet {
            Wallet(id: record.id.uuidString,
                identity: WalletIdentity(network: .mainnet, kind: .Quantum(record.identity), networkGlobalId: profile.globalID),
                metaData: metaData, setupSettings: setupSettings, batterySettings: BatterySettings())
        }
        try await TOSQuantumWalletCreation().create(words: mnemonic.mnemonicWords, profile: profile,
            saveMnemonic: { record in
                try await self.mnemonicsRepository.saveMnemonic(mnemonic, wallet: wallet(record), password: passcode)
                onEnrollment(record.id)
            }, publish: { record in
                try await self.walletsStore.addWallets([wallet(record)])
            })
    }

    public func importQuantumWallet(
        metaData: WalletMetaData,
        passcode: String,
        mnemonicWords: [String],
        profile: TOSQuantumNetworkProfile,
        setupSettings: WalletSetupSettings = WalletSetupSettings(),
        onEnrollment: (UUID) -> Void = { _ in }
    ) async throws {
        let mnemonicWords = TOSV1MnemonicValidator.normalize(mnemonicWords)
        guard TOSMnemonic.isValid(mnemonicWords) else {
            throw Mnemonic.Error.incorrectMnemonicWords
        }
        let mnemonic = try Mnemonic(mnemonicWords: mnemonicWords)
        func wallet(_ record: TOSQuantumCreationRecord) -> Wallet {
            Wallet(id: record.id.uuidString,
                identity: WalletIdentity(network: .mainnet, kind: .Quantum(record.identity), networkGlobalId: profile.globalID),
                metaData: metaData, setupSettings: setupSettings, batterySettings: BatterySettings())
        }
        try await TOSQuantumWalletCreation().restore(words: mnemonic.mnemonicWords, profile: profile,
            existing: { identity in
                let matches = try self.walletsStore.registeredWallets().filter { wallet in
                    guard case .Quantum(let current) = wallet.identity.kind else { return false }
                    return current == identity
                }
                guard matches.count <= 1 else { throw TOSPQError.keyBinding }
                guard let wallet = matches.first else { return nil }
                guard wallet.identity.networkGlobalId == profile.globalID,
                      let id = UUID(uuidString: wallet.id) else { throw TOSPQError.keyBinding }
                let prior = try TOSQuantumCreationRecord.load(id: id, baseDirectory: self.enrollmentDirectory)
                guard prior.published, prior.identity == identity, prior.profile == profile else { throw TOSPQError.keyBinding }
                return prior
            },
            confirmExisting: { record in
                guard let wallet = try self.walletsStore.registeredWallets().first(where: { UUID(uuidString: $0.id) == record.id }),
                      case .Quantum(let identity) = wallet.identity.kind, identity == record.identity,
                      wallet.identity.networkGlobalId == record.profile.globalID else { throw TOSPQError.keyBinding }
                let saved = try await self.mnemonicsRepository.getMnemonic(wallet: wallet, password: passcode)
                guard TOSV1MnemonicValidator.normalize(saved.mnemonicWords) == mnemonic.mnemonicWords else {
                    throw TOSPQError.keyBinding
                }
            },
            saveMnemonic: { record in
                try await self.mnemonicsRepository.saveMnemonic(mnemonic, wallet: wallet(record), password: passcode)
                onEnrollment(record.id)
            }, cleanupMnemonic: { record in
                try await self.mnemonicsRepository.deleteMnemonic(wallet: wallet(record), password: passcode)
            }, publish: { record in
                if let existing = try self.walletsStore.registeredWallets().first(where: { UUID(uuidString: $0.id) == record.id }),
                   case .Quantum(let identity) = existing.identity.kind, identity == record.identity {
                    _ = await self.walletsStore.makeWalletActive(existing)
                } else {
                    try await self.walletsStore.addWallets([wallet(record)])
                }
            })
    }

    public func quantumEnrollmentInventory() throws -> TOSQuantumCreationRecord.Scan {
        let registered = try walletsStore.registeredWallets()
        let scan = try TOSQuantumCreationRecord.scan(baseDirectory: enrollmentDirectory)
        let entries = scan.entries.filter { entry in
            guard let id = entry.id else { return true }
            return !registered.contains { UUID(uuidString: $0.id) == id }
        }
        return TOSQuantumCreationRecord.Scan(entries: entries, overflow: scan.overflow, storedCount: scan.storedCount)
    }

    /// Acquire and verify one fresh network proof before the onboarding flow
    /// asks the user to reveal a recovery phrase. No wallet state is created.
    public func preflightQuantumNetwork(profile: TOSQuantumNetworkProfile) async throws {
        try await TOSQuantumWalletCreation.preflight(profile: profile)
    }

    public func pendingQuantumEnrollments() throws -> [TOSQuantumCreationRecord.Entry] {
        try quantumEnrollmentInventory().entries
    }

    public func discardQuantumEnrollment(_ entry: TOSQuantumCreationRecord.Entry, passcode: String) async throws {
        let registered = try walletsStore.registeredWallets()
        if let id = entry.id, registered.contains(where: { UUID(uuidString: $0.id) == id }) { throw TOSPQError.keyBinding }
        // Published and unreadable records are always public-file cleanup only.
        // They can never authorize deleting a saved wallet's custody or phrase.
        if let record = entry.record, !record.published, mnemonicsRepository.hasMnemonics() {
            guard await mnemonicsRepository.checkIfPasswordValid(passcode) else { throw TOSPQError.keyBinding }
            let currentRegistry = try walletsStore.registeredWallets()
            guard !currentRegistry.contains(where: { UUID(uuidString: $0.id) == record.id }) else { throw TOSPQError.keyBinding }
            let current = try TOSQuantumCreationRecord.load(id: record.id, baseDirectory: enrollmentDirectory)
            guard !current.published, current.identity == record.identity, current.profile == record.profile else { throw TOSPQError.keyBinding }
            let wallet = Wallet(id: record.id.uuidString,
                identity: WalletIdentity(network: .mainnet, kind: .Quantum(record.identity), networkGlobalId: record.profile.globalID),
                metaData: WalletMetaData(label: "Unfinished wallet", tintColor: .defaultColor, icon: .icon(.wallet)),
                setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
            try removeEnrollmentRole(record.id, .primary)
            try removeEnrollmentRole(record.id, .rescue)
            try await mnemonicsRepository.deleteMnemonic(wallet: wallet, password: passcode)
            try removeEnrollmentCheckpoint(record.id)
        }
        try TOSQuantumCreationRecord.discard(entry, baseDirectory: enrollmentDirectory)
    }

    public func resumeQuantumCreation(id: UUID, metaData: WalletMetaData, passcode: String,
                                      setupSettings: WalletSetupSettings = WalletSetupSettings()) async throws {
        guard setupSettings.backupDate != nil else { throw TOSPQError.invalidInput }
        let record = try TOSQuantumCreationRecord.load(id: id, baseDirectory: enrollmentDirectory)
        guard !record.published else { throw TOSPQError.keyBinding }
        let registered = try walletsStore.registeredWallets()
        guard !registered.contains(where: { wallet in
            guard UUID(uuidString: wallet.id) != id, case .Quantum(let identity) = wallet.identity.kind else { return false }
            return identity == record.identity
        }) else { throw TOSPQError.keyBinding }
        let wallet: Wallet
        if let existing = registered.first(where: { UUID(uuidString: $0.id) == id }) {
            guard case .Quantum(let identity) = existing.identity.kind, identity == record.identity,
                  existing.identity.networkGlobalId == record.profile.globalID else { throw TOSPQError.keyBinding }
            var updated = existing
            updated.metaData = metaData
            updated.setupSettings = setupSettings
            wallet = updated
        } else {
            wallet = Wallet(id: record.id.uuidString,
                identity: WalletIdentity(network: .mainnet, kind: .Quantum(record.identity), networkGlobalId: record.profile.globalID),
                metaData: metaData, setupSettings: setupSettings, batterySettings: BatterySettings())
        }
        let mnemonic = try await mnemonicsRepository.getMnemonic(wallet: wallet, password: passcode)
        try await TOSQuantumWalletCreation().resume(words: mnemonic.mnemonicWords, record: record) { _ in
            try await self.walletsStore.addWallets([wallet])
        }
    }

    /// Return the protected phrase for an unfinished creation so the UI can
    /// require the normal backup challenge before publishing that wallet.
    public func pendingQuantumCreationMnemonic(id: UUID, passcode: String) async throws -> [String] {
        let record = try TOSQuantumCreationRecord.load(id: id, baseDirectory: enrollmentDirectory)
        guard !record.published else { throw TOSPQError.keyBinding }
        let registered = try walletsStore.registeredWallets()
        let wallet: Wallet
        if let existing = registered.first(where: { UUID(uuidString: $0.id) == id }) {
            guard case .Quantum(let identity) = existing.identity.kind,
                  identity == record.identity,
                  existing.identity.networkGlobalId == record.profile.globalID else { throw TOSPQError.keyBinding }
            wallet = existing
        } else {
            guard !registered.contains(where: { candidate in
                guard case .Quantum(let identity) = candidate.identity.kind else { return false }
                return identity == record.identity
            }) else { throw TOSPQError.keyBinding }
            wallet = Wallet(id: record.id.uuidString,
                identity: WalletIdentity(network: .mainnet, kind: .Quantum(record.identity), networkGlobalId: record.profile.globalID),
                metaData: WalletMetaData(label: "Unfinished wallet", tintColor: .defaultColor, icon: .icon(.wallet)),
                setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
        }
        let mnemonic = try await mnemonicsRepository.getMnemonic(wallet: wallet, password: passcode)
        let words = TOSV1MnemonicValidator.normalize(mnemonic.mnemonicWords)
        try TOSQuantumWalletCreation.requireMnemonicMatches(words: words, record: record)
        return words
    }

    public enum AddWalletRevisionError: Swift.Error {
        case unsupportedWalletKind
    }

    public func addWalletRevision(wallet: Wallet, revision: WalletContractVersion, passcode: String) async throws {
        guard try (revision == .tosV5R1) == (wallet.contractVersion == .tosV5R1) else {
            throw AddWalletRevisionError.unsupportedWalletKind
        }
        let mnemonic = try await mnemonicsRepository.getMnemonic(wallet: wallet, password: passcode)
        let keyPair = try WalletMnemonic.keyPair(words: mnemonic.mnemonicWords, wallet: wallet)

        let newWalletKind: WalletKind
        switch wallet.identity.kind {
        case let .Regular(publicKey, _):
            newWalletKind = .Regular(publicKey, revision)
        case let .Signer(publicKey, _):
            newWalletKind = .Signer(publicKey, revision)
        case let .SignerDevice(publicKey, _):
            newWalletKind = .SignerDevice(publicKey, revision)
        default:
            throw AddWalletRevisionError.unsupportedWalletKind
        }

        let newWalletIdentity = WalletIdentity(
            network: wallet.identity.network,
            kind: newWalletKind,
            networkGlobalId: revision == .tosV5R1 ? try await networkIdentityProvider(wallet.network) : wallet.identity.networkGlobalId
        )

        let wallet = Wallet(
            id: UUID().uuidString,
            identity: newWalletIdentity,
            metaData: wallet.metaData,
            setupSettings: wallet.setupSettings,
            batterySettings: BatterySettings()
        )

        await tonProofTokenService.loadTokensFor(
            pairs: [WalletPrivateKeyPair(
                wallet: wallet,
                privateKey: keyPair.privateKey
            )]
        )
        try await mnemonicsRepository.saveMnemonic(mnemonic, wallet: wallet, password: passcode)
        try await walletsStore.addWallets([wallet])
    }

    public func importWallets(
        phrase: [String],
        revisions: [WalletContractVersion],
        metaData: WalletMetaData,
        passcode: String,
        network: Network,
        format: WalletMnemonicFormat? = nil
    ) async throws {
        let phrase = TOSV1MnemonicValidator.normalize(phrase)
        guard TOSV1MnemonicValidator.isValid(phrase) else {
            throw Mnemonic.Error.incorrectMnemonicWords
        }
        let mnemonic = try Mnemonic(mnemonicWords: phrase)

        let resolvedFormat = try format ?? WalletMnemonicFormat.detect(words: phrase)
        guard WalletMnemonicFormat.validFormats(words: phrase).contains(resolvedFormat) else { throw WalletMnemonicFormat.Error.invalidPhrase }
        guard resolvedFormat != .tos || revisions.allSatisfy({ $0 == .tosV5R1 }),
              resolvedFormat != .legacyTON || !revisions.contains(.tosV5R1) else {
            throw WalletMnemonicFormat.Error.invalidPhrase
        }
        let keyPair = try resolvedFormat.keyPair(words: mnemonic.mnemonicWords)
        let tron: WalletTron?
        if resolvedFormat == .legacyTON {
            tron = await loadImportedWalletTronIfPositiveBalance(mnemonicWords: mnemonic.mnemonicWords, network: network)
        } else {
            tron = nil
        }

        let networkGlobalId = revisions.contains(.tosV5R1) ? try await networkIdentityProvider(network) : nil
        let labels = try ClassicWalletRecovery.labels(base: metaData.label, count: revisions.count)

        let wallets = revisions.enumerated().map { index, revision in
            let label = labels[index]
            let revisionMetaData = WalletMetaData(
                label: label,
                tintColor: metaData.tintColor,
                icon: metaData.icon
            )

            let walletIdentity = WalletIdentity(
                network: network,
                kind: .Regular(keyPair.publicKey, revision),
                networkGlobalId: revision == .tosV5R1 ? networkGlobalId : nil
            )

            return Wallet(
                id: UUID().uuidString,
                identity: walletIdentity,
                metaData: revisionMetaData,
                setupSettings: WalletSetupSettings(backupDate: Date()),
                batterySettings: BatterySettings(),
                tron: tron
            )
        }

        await tonProofTokenService.loadTokensFor(
            pairs: wallets.map {
                WalletPrivateKeyPair(
                    wallet: $0,
                    privateKey: keyPair.privateKey
                )
            }
        )
        try await mnemonicsRepository.saveMnemonic(
            mnemonic,
            wallets: wallets,
            password: passcode
        )
        try await walletsStore.addWallets(wallets)
    }

    private func loadImportedWalletTronIfPositiveBalance(
        mnemonicWords: [String],
        network: Network
    ) async -> WalletTron? {
        guard network == .mainnet else {
            return nil
        }

        guard let tronKeyPair = try? TonTron.derivedKeyPair(tonMnemonic: mnemonicWords, index: 0),
              let tronAddress = try? TronSwift.Address(publicKey: tronKeyPair.publicKey)
        else {
            return nil
        }

        guard let tronBalance = try? await tronBalanceService.loadBalance(
            address: tronAddress,
            includingTransferFees: true
        ), !tronBalance.amount.isZero else {
            return nil
        }

        return WalletTron(
            publicKey: tronKeyPair.publicKey,
            address: tronAddress,
            isOn: false
        )
    }

    public func importWatchOnlyWallet(
        resolvableAddress: ResolvableAddress,
        metaData: WalletMetaData
    ) async throws {
        let wallet = Wallet(
            id: UUID().uuidString,
            identity: WalletIdentity(network: .mainnet, kind: .Watchonly(resolvableAddress)),
            metaData: metaData,
            setupSettings: WalletSetupSettings(),
            batterySettings: BatterySettings()
        )
        try await walletsStore.addWallets([wallet])
    }

    public func importKeystoneWallet(
        publicKey: TonSwift.PublicKey,
        revisions: [WalletContractVersion],
        xfp: String?,
        path: String?,
        metaData: WalletMetaData
    ) async throws {
        guard !revisions.contains(.tosV5R1) else { throw TOSNetworkIdentityError.unsupportedSigner }
        let labels = try ClassicWalletRecovery.labels(base: metaData.label, count: revisions.count)

        let wallets = revisions.enumerated().map { index, revision in
            let label = labels[index]
            let revisionMetaData = WalletMetaData(
                label: label,
                tintColor: metaData.tintColor,
                icon: metaData.icon
            )

            let identity = WalletIdentity(
                network: .mainnet,
                kind: .Keystone(publicKey, xfp, path, revision)
            )

            return Wallet(
                id: UUID().uuidString,
                identity: identity,
                metaData: revisionMetaData,
                setupSettings: WalletSetupSettings(backupDate: Date()),
                batterySettings: BatterySettings()
            )
        }
        try await walletsStore.addWallets(wallets)
    }

    public func importSignerWallet(
        publicKey: TonSwift.PublicKey,
        revisions: [WalletContractVersion],
        metaData: WalletMetaData,
        isDevice: Bool
    ) async throws {
        guard !revisions.contains(.tosV5R1) else { throw TOSNetworkIdentityError.unsupportedSigner }
        let labels = try ClassicWalletRecovery.labels(base: metaData.label, count: revisions.count)

        let wallets = revisions.enumerated().map { index, revision in
            let label = labels[index]
            let revisionMetaData = WalletMetaData(
                label: label,
                tintColor: metaData.tintColor,
                icon: metaData.icon
            )

            let identity: WalletIdentity
            if isDevice {
                identity = WalletIdentity(
                    network: .mainnet,
                    kind: .SignerDevice(publicKey, revision)
                )
            } else {
                identity = WalletIdentity(
                    network: .mainnet,
                    kind: .Signer(publicKey, revision)
                )
            }

            return Wallet(
                id: UUID().uuidString,
                identity: identity,
                metaData: revisionMetaData,
                setupSettings: WalletSetupSettings(backupDate: Date()),
                batterySettings: BatterySettings()
            )
        }
        try await walletsStore.addWallets(wallets)
    }

    public func importLedgerWallets(
        accounts: [LedgerAccount],
        deviceId: String,
        deviceProductName: String,
        metaData: WalletMetaData
    ) async throws {
        let addPostfix = accounts.count > 1

        let wallets = accounts.enumerated().map { index, account in
            let label = addPostfix ? "\(metaData.label) \(index + 1)" : metaData.label
            let accountMetaData = WalletMetaData(
                label: label,
                tintColor: metaData.tintColor,
                icon: metaData.icon
            )

            let device = Wallet.LedgerDevice(deviceId: deviceId, deviceModel: deviceProductName, accountIndex: Int16(account.path.index))

            let identity = WalletIdentity(
                network: .mainnet,
                kind: .Ledger(account.publicKey, .v4R2, device)
            )

            return Wallet(
                id: UUID().uuidString,
                identity: identity,
                metaData: accountMetaData,
                setupSettings: WalletSetupSettings(backupDate: Date()),
                batterySettings: BatterySettings()
            )
        }
        try await walletsStore.addWallets(wallets)
    }
}
