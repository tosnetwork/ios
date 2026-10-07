import Foundation
import TonSwift
import CoreComponents

/// Locally reconstructed tuple; not deployment, POP, custody or migration approval.
public struct TOSQuantumInstalledRoute {
    public let moduleData: Cell, moduleInit: Cell, metadata: Cell, vaultData: Cell, vaultInit: Cell
    public let moduleAddress: Address, vaultAddress: Address
    /// Local identity check; installed module authentication is a separate requirement.
    public func requirePrimaryKey(_ publicKey: Data) throws {
        let data = try moduleData.beginParse()
        guard publicKey.count == 1312, data.remainingRefs == 1,
              try TOSPQWallet.byteChain(publicKey).hash() == data.loadRef().hash() else { throw TOSPQError.keyBinding }
    }
    /// Public-key identity only; private possession and operation eligibility are separate.
    public func requireRescueKey(_ publicKey: Data) throws {
        let identity = try moduleData.beginParse()
        try identity.skip(8 + 32 + 256 + 8)
        guard publicKey.count == 32, try publicKey == identity.loadBytes(32) else { throw TOSPQError.keyBinding }
    }
    private init(moduleData: Cell, moduleInit: Cell, metadata: Cell, vaultData: Cell, vaultInit: Cell, moduleAddress: Address, vaultAddress: Address) {
        self.moduleData = moduleData; self.moduleInit = moduleInit; self.metadata = metadata
        self.vaultData = vaultData; self.vaultInit = vaultInit; self.moduleAddress = moduleAddress; self.vaultAddress = vaultAddress
    }
    public static func initial(_ birth: TOSQuantumGenesis) -> Self {
        Self(moduleData: birth.moduleData, moduleInit: birth.moduleInit, metadata: birth.metadata,
             vaultData: birth.vaultData, vaultInit: birth.vaultInit, moduleAddress: birth.moduleAddress, vaultAddress: birth.vaultAddress)
    }
    public static func successor(birth: TOSQuantumGenesis, next: TOSQuantumGenesis) throws -> Self {
        guard try next.moduleInit.beginParse().loadRef().hash() == birth.moduleInit.beginParse().loadRef().hash(),
              try next.vaultInit.beginParse().loadRef().hash() == birth.vaultInit.beginParse().loadRef().hash() else { throw TOSPQError.keyBinding }
        let original = try birth.moduleData.beginParse(), replacement = try next.moduleData.beginParse()
        try original.skip(8); try replacement.skip(8)
        guard try original.loadBytes(36) == replacement.loadBytes(36) else { throw TOSPQError.keyBinding }
        let paired = try next.successorFor(wallet: birth.address).vaultInit
        let refs = try paired.beginParse(); _ = try refs.loadRef(); let data = try refs.loadRef()
        return Self(moduleData: next.moduleData, moduleInit: next.moduleInit, metadata: next.metadata,
                    vaultData: data, vaultInit: paired, moduleAddress: next.moduleAddress,
                    vaultAddress: Address(workchain: 0, hash: paired.hash()))
    }
}
