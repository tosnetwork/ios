import Foundation
import TonSwift
import CoreComponents

public enum TOSQuantumAction {
    case execute(Cell)
    case configure(replacement: (metadata: Cell, vaultInit: Cell)?)
    case lockPrimary
    case migrate(moduleInit: Cell, metadata: Cell, vaultInit: Cell)
}

/// PQ-only AUTH wire framing. Fresh authenticated state and custody are separate requirements.
public struct TOSQuantumAuth {
    public let request: Cell
    public let digest: Data
    public let role: TOSQuantumRole
    public init(globalId: Int32, network: Data, wallet: Address, module: Address,
                role: TOSQuantumRole, epoch: UInt64, nonce: UInt64, validUntil: UInt32,
                action: TOSQuantumAction, provenTime: UInt32) throws {
        guard network.count == 32, wallet.workchain == 0, module.workchain == 0,
              wallet.hash != module.hash, validUntil > provenTime,
              UInt64(validUntil) - UInt64(provenTime) <= 3600 else { throw TOSPQError.invalidInput }
        let kind: UInt8
        let payload: Cell
        switch action {
        case .execute(let actions):
            try Self.validateActions(actions)
            kind = 0; payload = try Builder().store(uint: 0x45584543, bits: 32).store(ref: actions).endCell()
        case .configure(let replacement):
            kind = 1
            let b = try Builder().store(uint: 0x434f4e46, bits: 32).store(uint: 2, bits: 2).store(bit: replacement != nil)
            if let pair = replacement { try b.store(ref: Builder().store(ref: pair.metadata).store(ref: pair.vaultInit).endCell()) }
            payload = try b.endCell()
        case .lockPrimary:
            kind = 3; payload = try Builder().store(uint: 0x4c4f434b, bits: 32).store(uint: 1, bits: 8).endCell()
        case .migrate(let moduleInit, let metadata, let vaultInit):
            kind = 4; payload = try Builder().store(uint: 0x4d494752, bits: 32)
                .store(ref: moduleInit).store(ref: metadata).store(ref: vaultInit).endCell()
        }
        guard role != .primary || kind == 0 else { throw TOSPQError.invalidInput }
        self.role = role
        request = try Builder().store(uint: 0x41553252, bits: 32).store(int: globalId, bits: 32)
            .store(data: network).store(wallet).store(data: module.hash).store(uint: role.rawValue, bits: 8)
            .store(uint: epoch, bits: 64).store(uint: nonce, bits: 64).store(uint: validUntil, bits: 32)
            .store(uint: kind, bits: 8).store(ref: payload).endCell()
        digest = try Builder().store(data: Data("TOS-AUTH".utf8)).store(ref: request).endCell().hash()
    }
    public func submission(signature: Data) throws -> Cell {
        guard signature.count == role.signatureSize else { throw TOSPQError.invalidInput }
        return try Builder().store(uint: 0x53554233, bits: 32).store(ref: request)
            .store(ref: TOSPQWallet.byteChain(signature)).endCell()
    }
    public static func validateActions(_ actions: Cell) throws {
        var current = actions
        var count = 0
        while true {
            let s = try current.beginParse()
            if s.remainingBits == 0 {
                guard s.remainingRefs == 0 else { throw TOSPQError.invalidInput }; return
            }
            guard count < 255, s.remainingBits == 40, s.remainingRefs == 2,
                  try s.loadUint(bits: 32) == 0x0ec3c86d else { throw TOSPQError.invalidInput }
            let mode = try s.loadUint(bits: 8)
            guard mode & 2 != 0, mode & 44 == 0, mode & 192 != 192 else { throw TOSPQError.invalidInput }
            current = try s.loadRef(); count += 1
        }
    }
}
