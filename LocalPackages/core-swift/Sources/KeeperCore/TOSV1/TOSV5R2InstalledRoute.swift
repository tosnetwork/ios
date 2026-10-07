import Foundation
import TonSwift
import CoreComponents

/// Locally reconstructed tuple; not deployment, POP, custody or migration approval.
public struct TOSV5R2InstalledRoute {
    public let moduleData: Cell, moduleInit: Cell, metadata: Cell, vaultData: Cell, vaultInit: Cell
    public let moduleAddress: Address, vaultAddress: Address
    private init(moduleData: Cell, moduleInit: Cell, metadata: Cell, vaultData: Cell, vaultInit: Cell, moduleAddress: Address, vaultAddress: Address) {
        self.moduleData = moduleData; self.moduleInit = moduleInit; self.metadata = metadata
        self.vaultData = vaultData; self.vaultInit = vaultInit; self.moduleAddress = moduleAddress; self.vaultAddress = vaultAddress
    }
    public static func initial(_ birth: TOSV5R2Genesis) -> Self {
        Self(moduleData: birth.moduleData, moduleInit: birth.moduleInit, metadata: birth.metadata,
             vaultData: birth.vaultData, vaultInit: birth.vaultInit, moduleAddress: birth.moduleAddress, vaultAddress: birth.vaultAddress)
    }
    public static func successor(birth: TOSV5R2Genesis, next: TOSV5R2Genesis) throws -> Self {
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
