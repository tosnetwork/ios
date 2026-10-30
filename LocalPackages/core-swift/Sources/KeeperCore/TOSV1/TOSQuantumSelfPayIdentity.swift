import Foundation
import TonSwift
import CoreComponents

/// Immutable public identity, retained across key rotation. Contains no custody secrets.
/// QSI1 || basechain address hash || ^original StateInit. Current state is never a birth identity.
public struct TOSQuantumSelfPayIdentity: Codable, Hashable {
    public let wallet: TOSQuantumSelfPayWallet
    public let cell: Cell
    public var address: Address { wallet.address }
    public static let maximumBOCBytes = 16384

    public init(wallet: TOSQuantumSelfPayWallet) throws {
        self.wallet = wallet
        cell = try Builder().store(uint: 0x51534931, bits: 32).store(data: wallet.address.hash)
            .store(ref: wallet.stateInit).endCell()
    }

    public func toBOC() throws -> Data { try cell.toBoc() }

    public func requireNetwork(globalID: Int32, namespace: Data) throws {
        guard wallet.initialAuthority.globalID == globalID, wallet.initialAuthority.namespace == namespace else {
            throw TOSPQError.keyBinding
        }
    }

    public init(boc: Data) throws {
        guard (1...Self.maximumBOCBytes).contains(boc.count) else { throw TOSPQError.invalidInput }
        // The pinned SDK indexes BOC references without bounds checks. Reuse
        // the structural preflight before any untrusted backup reaches it.
        try self.init(cell: TOSRPCOrdinaryBOC.decode(boc.base64EncodedString()))
    }

    public init(cell: Cell) throws {
        try TOSQuantumSelfPayAuthority.ordinary(cell)
        let s = try cell.beginParse()
        guard s.remainingBits == 288, s.remainingRefs == 1, try s.loadUint(bits: 32) == 0x51534931 else {
            throw TOSPQError.invalidInput
        }
        let expected = Address(workchain: 0, hash: try s.loadBytes(32)), stateInit = try s.loadRef()
        try TOSQuantumSelfPayAuthority.ordinary(stateInit)
        let initial = try stateInit.beginParse()
        guard initial.remainingBits == 5, initial.remainingRefs == 2, try initial.loadUint(bits: 5) == 6 else {
            throw TOSPQError.invalidInput
        }
        let code = try initial.loadRef()
        try TOSQuantumSelfPayAuthority.ordinary(code)
        guard try code.hash() == TOSQuantumSelfPayCode.wallet().hash() else { throw TOSPQError.keyBinding }
        let state = try TOSQuantumSelfPayState.parse(initial.loadRef())
        guard state.seqno == 0, state.epoch == 0, state.retired == 0, state.primaryNonce == 0, state.rescueNonce == 0 else {
            throw TOSPQError.invalidInput
        }
        let wallet = try TOSQuantumSelfPayWallet(authority: state.authority, walletID: state.walletID)
        guard wallet.address == expected, wallet.stateInit.hash() == stateInit.hash() else { throw TOSPQError.keyBinding }
        try self.init(wallet: wallet)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard encoded.utf8.count <= 4 * ((Self.maximumBOCBytes + 2) / 3),
              let boc = Data(base64Encoded: encoded) else { throw TOSPQError.invalidInput }
        try self.init(boc: boc)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(toBOC().base64EncodedString())
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.cell.hash() == rhs.cell.hash() }
    public func hash(into hasher: inout Hasher) { hasher.combine(cell.hash()) }
}
