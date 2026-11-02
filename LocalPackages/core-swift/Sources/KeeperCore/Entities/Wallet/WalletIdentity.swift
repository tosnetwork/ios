import Foundation
import TonSwift

public struct WalletIdentity: Equatable, Hashable {
    public let network: Network
    public let kind: WalletKind
    /// Discovered from the selected TOS node; absent in legacy identities.
    public let networkGlobalId: Int32?

    public init(network: Network, kind: WalletKind, networkGlobalId: Int32? = nil) {
        self.network = network
        self.kind = kind
        if case .Quantum(let identity) = kind {
            self.networkGlobalId = networkGlobalId ?? identity.wallet.initialAuthority.globalID
        } else {
            self.networkGlobalId = networkGlobalId
        }
    }

    public func identifier() throws -> WalletID {
        let builder = Builder()
        try builder.store(self)
        return try WalletID(hash: builder.endCell().representationHash())
    }
}

extension WalletIdentity: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let identityBinaryString = try container.decode(String.self)
        if identityBinaryString.hasPrefix("qsp1:") {
            let encoded = String(identityBinaryString.dropFirst(5))
            guard encoded.utf8.count <= 4 * ((TOSQuantumSelfPayIdentity.maximumBOCBytes + 128 + 2) / 3) else {
                throw TOSNetworkIdentityError.missingIdentity
            }
            let slice = try TOSRPCOrdinaryBOC.decode(encoded).beginParse()
            self = try Self.loadFrom(slice: slice)
            guard case .Quantum = kind else { throw TOSNetworkIdentityError.missingIdentity }
            try slice.endParse()
            return
        }
        let identityBitstring = try Bitstring(binaryString: identityBinaryString)
        self = try Slice(bits: identityBitstring).loadType()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if case .Quantum = kind {
            // The original identity representation stored only root bits. The
            // Quantum birth descriptor has references, so persist the full BOC.
            let cell = try Builder().store(self).endCell()
            try container.encode("qsp1:" + cell.toBoc().base64EncodedString())
            return
        }
        let identityBinaryString = try Builder().store(self).bitstring().toBinary()
        try container.encode(identityBinaryString)
    }
}

extension WalletIdentity: CellCodable {
    public func storeTo(builder: Builder) throws {
        if case .Quantum(let identity) = kind {
            guard networkGlobalId == identity.wallet.initialAuthority.globalID else {
                throw TOSNetworkIdentityError.missingIdentity
            }
        }
        try network.storeTo(builder: builder)
        try kind.storeTo(builder: builder)
        if kind.usesTOSNetworkIdentity {
            guard let networkGlobalId else { throw TOSNetworkIdentityError.missingIdentity }
            try builder.store(int: networkGlobalId, bits: 32)
        }
    }

    public static func loadFrom(slice: Slice) throws -> WalletIdentity {
        return try slice.tryLoad { s in
            let network: Network = try s.loadType()
            let kind: WalletKind = try s.loadType()
            let globalId = kind.usesTOSNetworkIdentity ? Int32(try s.loadInt(bits: 32)) : nil
            if case .Quantum(let identity) = kind {
                guard globalId == identity.wallet.initialAuthority.globalID else {
                    throw TOSNetworkIdentityError.missingIdentity
                }
            }
            return WalletIdentity(network: network, kind: kind, networkGlobalId: globalId)
        }
    }
}

private extension WalletKind {
    var usesTOSNetworkIdentity: Bool {
        switch self {
        case .Quantum:
            return true
        case let .Regular(_, revision), let .Signer(_, revision), let .SignerDevice(_, revision),
             let .Ledger(_, revision, _), let .Keystone(_, _, _, revision):
            return revision == .tosV5R1
        case .Lockup, .Watchonly:
            return false
        }
    }
}
