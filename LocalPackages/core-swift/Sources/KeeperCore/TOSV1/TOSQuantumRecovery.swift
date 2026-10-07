import Foundation
import BigInt
import TonSwift
import CoreComponents

public struct TOSQuantumRecoveryBinding {
    public let globalId: Int32, network: Data, wallet: Address, module: Address, validUntil: UInt32
    public init(globalId: Int32, network: Data, wallet: Address, module: Address, validUntil: UInt32) {
        self.globalId = globalId; self.network = network; self.wallet = wallet; self.module = module; self.validUntil = validUntil
    }
    fileprivate func validate(_ time: UInt32) throws {
        guard network.count == 32, wallet.workchain == 0, module.workchain == 0,
              wallet.hash != module.hash, validUntil > time, UInt64(validUntil) - UInt64(time) <= 3600 else { throw TOSPQError.invalidInput }
    }
}
/// POP framing. Fresh challenge generation and authenticated funded receipts are separate requirements.
public struct TOSQuantumPop {
    public let request: Cell, digest: Data, role: TOSQuantumRole
    public let signingContext = "TOS-RESCUE-POP-v1"
    public init(binding b: TOSQuantumRecoveryBinding, role: TOSQuantumRole, policy: TOSQuantumPolicy,
                primaryKeyChainHash: Data, rescueKey: Data, challenge: Data, provenTime: UInt32) throws {
        try b.validate(provenTime)
        guard primaryKeyChainHash.count == 32, rescueKey.count == 32,
              challenge.count == 32, challenge.contains(where: { $0 != 0 }) else { throw TOSPQError.invalidInput }
        let parties = try Builder().store(b.wallet).store(data: b.module.hash).endCell()
        let keys = try Builder().store(uint: 1, bits: 8).store(data: primaryKeyChainHash).store(data: rescueKey)
            .store(uint: policy.rawValue, bits: 8).endCell()
        let cell = try Builder().store(uint: 0x504f5033, bits: 32).store(int: b.globalId, bits: 32).store(data: b.network)
            .store(uint: role.rawValue, bits: 8).store(data: challenge).store(uint: b.validUntil, bits: 32)
            .store(ref: parties).store(ref: keys).endCell()
        self.role = role; request = cell
        digest = try Builder().store(data: Data("TOS-POP1".utf8)).store(ref: cell).endCell().hash()
    }
    public func submission(signature: Data) throws -> Cell {
        guard signature.count == role.signatureSize else { throw TOSPQError.invalidInput }
        return try Builder().store(uint: 0x50505333, bits: 32).store(ref: request)
            .store(ref: TOSPQWallet.byteChain(signature)).endCell()
    }
}
/// SLH-only deployment intent. Witness pairing, current fee limits and deployment must be verified separately.
public struct TOSQuantumPreparation {
    public let request: Cell, digest: Data, deploymentValue: BigUInt
    public let signingContext = "TOS-RESCUE-FEE-PREP-v1"
    public init(binding b: TOSQuantumRecoveryBinding, moduleAmount: BigUInt, vaultAmount: BigUInt,
                moduleInit: Cell, metadata: Cell, vaultInit: Cell, provenTime: UInt32) throws {
        try b.validate(provenTime)
        guard moduleAmount > 0, vaultAmount > 0, moduleAmount.bitWidth <= 120, vaultAmount.bitWidth <= 120 else { throw TOSPQError.invalidInput }
        // Exact arbitrary-precision sum of two bounded Coins fields, at most 121 bits.
        deploymentValue = moduleAmount + vaultAmount
        let a = (moduleAmount.bitWidth + 7) / 8, v = (vaultAmount.bitWidth + 7) / 8
        let targets = try Builder().store(uint: a, bits: 4).store(biguint: moduleAmount, bits: a * 8)
            .store(uint: v, bits: 4).store(biguint: vaultAmount, bits: v * 8)
            .store(ref: moduleInit).store(ref: metadata).store(ref: vaultInit).endCell()
        let cell = try Builder().store(uint: 0x50525033, bits: 32).store(int: b.globalId, bits: 32).store(data: b.network)
            .store(b.wallet).store(data: b.module.hash).store(uint: b.validUntil, bits: 32).store(ref: targets).endCell()
        request = cell; digest = cell.hash()
    }
    public func submission(signature: Data) throws -> Cell {
        guard signature.count == 7856 else { throw TOSPQError.invalidInput }
        return try Builder().store(uint: 0x46505233, bits: 32).store(ref: request)
            .store(ref: TOSPQWallet.byteChain(signature)).endCell()
    }
}
