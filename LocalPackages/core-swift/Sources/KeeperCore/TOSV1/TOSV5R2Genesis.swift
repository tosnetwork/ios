import Foundation
import TonSwift
import CoreComponents

public enum TOSV5R2Policy: UInt8, Codable, Sendable { case ready = 1, required = 2 }
public struct TOSV5R2Codes {
    public let wallet: Cell, module: Cell, vault: Cell
    public init(wallet: Cell, module: Cell, vault: Cell) { self.wallet = wallet; self.module = module; self.vault = vault }
}
/// Pins must be authenticated independently of the supplied code and RPC data.
public struct TOSV5R2CodePins {
    public let wallet: Data, module: Data, vault: Data
    public init(wallet: Data, module: Data, vault: Data) { self.wallet = wallet; self.module = module; self.vault = vault }
}
/// Complete PQ-only construction DAG. Code identity and pairing are not deployment or POP approval.
public struct TOSV5R2Genesis {
    private let codes: TOSV5R2Codes
    private let globalId: Int32
    private let network: Data
    private let epoch0: UInt32
    private let feeKey: Cell
    public let moduleData: Cell, moduleInit: Cell, metadata: Cell
    public let walletData: Cell, walletInit: Cell, vaultData: Cell, vaultInit: Cell
    public let address: Address, moduleAddress: Address, vaultAddress: Address
    public let configHash: Data
    public init(codes: TOSV5R2Codes, pins: TOSV5R2CodePins, globalId: Int32, network: Data,
                walletId: UInt32, primaryKey: Data, rescueKey: Data, policy: TOSV5R2Policy,
                feeTreeId: Data, feePublicKey: Data, epoch0: UInt32) throws {
        try Self.checkCode(codes.wallet, pins.wallet); try Self.checkCode(codes.module, pins.module); try Self.checkCode(codes.vault, pins.vault)
        guard network.count == 32, primaryKey.count == 1312, rescueKey.count == 32,
              feeTreeId.count == 32, feePublicKey.count == 60,
              feePublicKey.prefix(12) == Data([0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0, 3]) else { throw TOSPQError.invalidInput }
        let md = try Builder().store(uint: 1, bits: 8).store(int: globalId, bits: 32).store(data: network)
            .store(uint: 1, bits: 8).store(ref: TOSPQWallet.byteChain(primaryKey)).store(data: rescueKey)
            .store(uint: policy.rawValue, bits: 8).endCell()
        let mi = try Self.stateInit(code: codes.module, data: md)
        let ma = Address(workchain: 0, hash: mi.hash())
        let key = try TOSPQWallet.byteChain(feePublicKey)
        let meta = try Builder().store(uint: 1, bits: 8).store(uint: 1, bits: 8).store(data: feeTreeId)
            .store(uint: epoch0, bits: 32).store(uint: 3600, bits: 32).store(uint: 4, bits: 16).store(ref: key).endCell()
        let auth = try Builder().store(uint: 4, bits: 8).store(uint: 2, bits: 2).store(uint: 0, bits: 16)
            .store(uint: 1, bits: 64).store(uint: 0, bits: 64).store(uint: 0, bits: 64).store(ref: mi).store(ref: meta).endCell()
        let wd = try Builder().store(bit: false).store(uint: 0, bits: 32).store(uint: walletId, bits: 32)
            .store(data: Data(count: 32)).store(bit: false).store(ref: auth).endCell()
        let wi = try Self.stateInit(code: codes.wallet, data: wd)
        let wa = Address(workchain: 0, hash: wi.hash())
        let paired = try Self.pairedVault(globalId: globalId, network: network, wallet: wa, module: ma, metadata: meta, key: key, epoch0: epoch0)
        let vi = try Self.stateInit(code: codes.vault, data: paired.data)
        self.codes = codes; self.globalId = globalId; self.network = network; self.epoch0 = epoch0; feeKey = key
        moduleData = md; moduleInit = mi; metadata = meta; moduleAddress = ma
        walletData = wd; walletInit = wi; address = wa
        vaultData = paired.data; vaultInit = vi; vaultAddress = Address(workchain: 0, hash: vi.hash()); configHash = paired.config
    }
    private static func pairedVault(globalId: Int32, network: Data, wallet: Address, module: Address,
                                    metadata: Cell, key: Cell, epoch0: UInt32) throws -> (data: Cell, config: Data) {
        let config = try Builder().store(uint: 1, bits: 8).store(int: globalId, bits: 32).store(data: network)
            .store(wallet).store(module).store(ref: metadata).endCell().hash()
        let prefix = try Builder().store(uint: 0x41553252, bits: 32).store(int: globalId, bits: 32)
            .store(data: network).store(wallet).store(data: module.hash).store(uint: 2, bits: 8).endCell()
        let parties = try Builder().store(wallet).store(data: module.hash).endCell().hash()
        let data = try Builder().store(uint: 3, bits: 8).store(uint: 0, bits: 32).store(data: config).store(uint: epoch0, bits: 32)
            .store(module).store(data: parties).store(ref: key).store(ref: prefix).endCell()
        return (data, config)
    }
    /// Retargets the new vault to the original address; fresh-key and live-state checks remain mandatory.
    public func successorFor(wallet: Address) throws -> (vaultInit: Cell, configHash: Data) {
        guard wallet.workchain == 0, wallet.hash != moduleAddress.hash else { throw TOSPQError.invalidInput }
        let paired = try Self.pairedVault(globalId: globalId, network: network, wallet: wallet, module: moduleAddress,
                                          metadata: metadata, key: feeKey, epoch0: epoch0)
        return (try Self.stateInit(code: codes.vault, data: paired.data), paired.config)
    }
    private static func stateInit(code: Cell, data: Cell) throws -> Cell {
        try Builder().store(uint: 6, bits: 5).store(ref: code).store(ref: data).endCell()
    }
    private static func checkCode(_ code: Cell, _ pin: Data) throws {
        guard pin.count == 32, code.hash() == pin else { throw TOSPQError.keyBinding }
        var pending = [code]; var seen = Set<Cell>()
        while let current = pending.popLast() {
            if !seen.insert(current).inserted { continue }
            guard !current.isExotic, current.level == 0 else { throw TOSPQError.invalidInput }
            pending.append(contentsOf: current.refs)
        }
    }
}
