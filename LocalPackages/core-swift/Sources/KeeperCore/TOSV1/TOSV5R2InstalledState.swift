import Foundation
import TonSwift
import CoreComponents

/// Strict data codec; parsing alone does not authenticate chain state or authorize signing.
public struct TOSV5R2WalletData {
    public let seqno: UInt32, walletID: UInt32, retired: UInt16
    public let epoch: UInt64, primaryNonce: UInt64, rescueNonce: UInt64
    public static func parse(_ data: Cell, birth: TOSV5R2Genesis, module: Cell? = nil, metadata: Cell? = nil) throws -> Self {
        guard !data.isExotic, data.level == 0 else { throw TOSPQError.invalidInput }
        let s = try data.beginParse()
        guard s.remainingBits == 322, s.remainingRefs == 1, try s.loadBoolean() == false else { throw TOSPQError.invalidInput }
        let seqno = UInt32(try s.loadUint(bits: 32)), walletID = UInt32(try s.loadUint(bits: 32))
        guard try s.loadBytes(32) == Data(count: 32), try s.loadBoolean() == false else { throw TOSPQError.invalidInput }
        let original = try birth.walletData.beginParse(); try original.skip(33)
        guard walletID == UInt32(try original.loadUint(bits: 32)) else { throw TOSPQError.keyBinding }
        let cell = try s.loadRef()
        guard !cell.isExotic, cell.level == 0 else { throw TOSPQError.invalidInput }
        let a = try cell.beginParse()
        guard a.remainingBits == 218, a.remainingRefs == 2,
              try a.loadUint(bits: 8) == 4, try a.loadUint(bits: 2) == 2 else { throw TOSPQError.invalidInput }
        let retired = UInt16(try a.loadUint(bits: 16))
        let epoch = try a.loadUint(bits: 64), primary = try a.loadUint(bits: 64), rescue = try a.loadUint(bits: 64)
        guard try a.loadRef().hash() == (module ?? birth.moduleInit).hash(),
              try a.loadRef().hash() == (metadata ?? birth.metadata).hash() else { throw TOSPQError.keyBinding }
        return Self(seqno: seqno, walletID: walletID, retired: retired, epoch: epoch, primaryNonce: primary, rescueNonce: rescue)
    }
}

public enum TOSV5R2AccountState {
    /// TOS block.tlb StorageUsed + StorageExtraInfo; the old TON Account codec is insufficient.
    public static func data(_ boc: Data, expectedAddress: Address, expectedCode: Cell) throws -> Cell {
        guard (1...67_108_864).contains(boc.count), expectedAddress.workchain == 0 else { throw TOSPQError.invalidInput }
        let roots = try Cell.fromBoc(src: boc)
        guard roots.count == 1, !roots[0].isExotic, roots[0].level == 0 else { throw TOSPQError.invalidInput }
        let s = try roots[0].beginParse()
        guard try s.loadBoolean() else { throw TOSPQError.invalidInput }
        let address: Address = try s.loadType()
        guard address == expectedAddress else { throw TOSPQError.keyBinding }
        for _ in 0..<2 {
            let bytes = Int(try s.loadUint(bits: 3))
            guard bytes < 7 else { throw TOSPQError.invalidInput }
            try s.skip(bytes * 8)
        }
        switch try s.loadUint(bits: 3) {
        case 0: break
        case 1: try s.skip(256)
        default: throw TOSPQError.invalidInput
        }
        try s.skip(32)
        if try s.loadBoolean() { let bytes = Int(try s.loadUint(bits: 4)); try s.skip(bytes * 8) }
        try s.skip(64)
        let balanceBytes = Int(try s.loadUint(bits: 4)); try s.skip(balanceBytes * 8)
        if try s.loadBoolean() { _ = try s.loadRef() }
        guard try s.loadBoolean(), try s.loadBoolean() == false, try s.loadBoolean() == false, try s.loadBoolean() else { throw TOSPQError.invalidInput }
        let code = try s.loadRef()
        guard try s.loadBoolean() else { throw TOSPQError.invalidInput }
        let data = try s.loadRef()
        guard try s.loadBoolean() == false, !code.isExotic, code.level == 0, code.hash() == expectedCode.hash(),
              !data.isExotic, data.level == 0 else { throw TOSPQError.keyBinding }
        try s.endParse()
        return data
    }
    public static func vaultCounter(_ data: Cell, expected: Cell) throws -> UInt32 {
        guard !data.isExotic, data.level == 0 else { throw TOSPQError.invalidInput }
        let s = try data.beginParse(), e = try expected.beginParse()
        guard s.remainingBits == e.remainingBits, s.remainingRefs == e.remainingRefs,
              try s.loadUint(bits: 8) == 3 else { throw TOSPQError.invalidInput }
        try e.skip(8)
        let next = UInt32(try s.loadUint(bits: 32)); try e.skip(32)
        guard next <= 1_048_576, try s.toCell().hash() == e.toCell().hash() else { throw TOSPQError.keyBinding }
        return next
    }
}

/// Authenticated initial tuple observation. Global policy, custody, fee-slot/solvency
/// and signing/action checks are additional gates; this does not confer readiness.
public struct TOSV5R2InstalledWallet {
    public let state: TOSV5R2WalletData, nextFeeLeaf: UInt32
    private let walletProof: TOSV5R2ProofBridge.BoundRead, network: Data, policy: UInt64
    private let vaultTime: UInt32, epoch0: UInt32
    private init(state: TOSV5R2WalletData, nextFeeLeaf: UInt32, walletProof: TOSV5R2ProofBridge.BoundRead, network: Data, policy: UInt64, vaultTime: UInt32, epoch0: UInt32) {
        self.state = state; self.nextFeeLeaf = nextFeeLeaf; self.walletProof = walletProof; self.network = network; self.policy = policy; self.vaultTime = vaultTime; self.epoch0 = epoch0
    }
    /// Chain eligibility only; custody, fee and signed-action gates still apply.
    public func requirePrimaryExecution(policyProof: TOSV5R2ProofBridge.BoundRead, now: Int64, maximumAge: Int64) throws {
        try walletProof.requireLive(now: now, maximumAge: maximumAge)
        try walletProof.requireSameCheckpoint(policyProof)
        guard policy == 1, state.retired & 2 == 0, state.seqno < UInt32.max, state.primaryNonce < UInt64.max,
              now >= 0, now <= Int64(UInt32.max) else { throw TOSPQError.keyBinding }
        let roots = try Cell.fromBoc(src: policyProof.provenConfigParam(48))
        guard roots.count == 1 else { throw TOSPQError.invalidInput }
        try TOSV5R2RetirementPolicy.requirePrimary(roots[0], network: network, now: UInt32(now))
    }
    public func requireFeeProof(now: Int64, maximumAge: Int64) throws {
        try walletProof.requireLive(now: now, maximumAge: maximumAge)
        guard now >= 0, now <= Int64(UInt32.max), maximumAge > 0, maximumAge < 3600 else { throw TOSPQError.invalidInput }
        try TOSV5R2FeeProofTime.check(master: walletProof.masterchainTime(), shard: vaultTime,
                                   now: UInt32(now), maximumAge: UInt32(maximumAge), epoch0: epoch0)
    }
    public static func bindInitial(birth: TOSV5R2Genesis, wallet: TOSV5R2ProofBridge.BoundRead,
                                   module: TOSV5R2ProofBridge.BoundRead, vault: TOSV5R2ProofBridge.BoundRead,
                                   now: Int64, maximumAge: Int64) throws -> Self {
        try wallet.requireLive(now: now, maximumAge: maximumAge)
        try wallet.requireSameCheckpoint(module); try wallet.requireSameCheckpoint(vault)
        func data(_ proof: TOSV5R2ProofBridge.BoundRead, address: Address, initCell: Cell) throws -> Cell {
            let code = try initCell.beginParse().loadRef()
            let text = "0:" + address.hash.map { String(format: "%02x", $0) }.joined()
            return try TOSV5R2AccountState.data(proof.accountState(expectedAddress: text, expectedCodeHash: code.hash()),
                                               expectedAddress: address, expectedCode: code)
        }
        let wd = try data(wallet, address: birth.address, initCell: birth.walletInit)
        let md = try data(module, address: birth.moduleAddress, initCell: birth.moduleInit)
        let vd = try data(vault, address: birth.vaultAddress, initCell: birth.vaultInit)
        guard md.hash() == birth.moduleData.hash() else { throw TOSPQError.keyBinding }
        let identity = try md.beginParse(); try identity.skip(40)
        let network = try identity.loadBytes(32); try identity.skip(8 + 256)
        let policy = try identity.loadUint(bits: 8)
        let metadata = try birth.metadata.beginParse(); try metadata.skip(272)
        let epoch0 = UInt32(try metadata.loadUint(bits: 32))
        let vaultAddress = "0:" + birth.vaultAddress.hash.map { String(format: "%02x", $0) }.joined()
        let vaultCode = try birth.vaultInit.beginParse().loadRef().hash()
        let vaultTime = try vault.accountTime(expectedAddress: vaultAddress, expectedCodeHash: vaultCode)
        return try Self(state: TOSV5R2WalletData.parse(wd, birth: birth),
                        nextFeeLeaf: TOSV5R2AccountState.vaultCounter(vd, expected: birth.vaultData),
                        walletProof: wallet, network: network, policy: policy, vaultTime: vaultTime, epoch0: epoch0)
    }
}
