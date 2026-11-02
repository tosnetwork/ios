import Foundation
import BigInt
import TonSwift
import CoreComponents

/// A fresh account observation bound to the retained birth identity. It does not
/// authorize signing or attest to custody, gas affordability or transaction success.
/// Reading a REQUIRED/rescue wallet does not depend on PRIMARY policy availability.
public struct TOSQuantumSelfPayAccount {
    public enum Status {
        case absent
        case uninitialized
        case frozen(Data)
        case active(TOSQuantumSelfPayState)
    }
    public struct Snapshot {
        public let status: Status
        public let balance: BigUInt, storageDebt: BigUInt
        public let lastPaid: UInt32
    }
    private let proof: TOSQuantumProofBridge.BoundRead
    private let observed: Snapshot
    private let shardTime: UInt32
    private let maximumAge: Int64

    public init(identity: TOSQuantumSelfPayIdentity, proof: TOSQuantumProofBridge.BoundRead,
                now: Int64, maximumAge: Int64) throws {
        guard (1...3599).contains(maximumAge) else { throw TOSPQError.invalidInput }
        try proof.requireLive(now: now, maximumAge: maximumAge)
        let address = "0:" + identity.address.hash.map { String(format: "%02x", $0) }.joined()
        observed = try Self.decode(proof.provenAccountState(expectedAddress: address), wallet: identity.wallet)
        shardTime = try proof.provenAccountTime(expectedAddress: address)
        self.proof = proof
        self.maximumAge = maximumAge
        _ = try snapshot(now: now)
    }

    /// Raw recorded balance/debt; pending fees still have to be calculated before spending.
    public func snapshot(now: Int64) throws -> Snapshot {
        try proof.requireLive(now: now, maximumAge: maximumAge)
        try Self.validateTime(master: proof.masterchainTime(), shard: shardTime, now: now, maximumAge: maximumAge)
        return observed
    }

    internal static func validateTime(master: UInt32, shard: UInt32, now: Int64, maximumAge: Int64) throws {
        guard now > 0, (1...3599).contains(maximumAge), shard <= master,
              (-60...maximumAge).contains(now - Int64(shard)) else { throw TOSPQError.invalidInput }
    }

    /// Pure codec only. Only the proof constructor can mint the account capability.
    internal static func decode(_ boc: Data?, wallet: TOSQuantumSelfPayWallet) throws -> Snapshot {
        guard let boc else { return Snapshot(status: .absent, balance: 0, storageDebt: 0, lastPaid: 0) }
        let root = try TOSRPCOrdinaryBOC.decode(boc.base64EncodedString())
        let s = try root.beginParse()
        guard try s.loadBoolean() else { throw TOSPQError.invalidInput }
        let address: Address = try s.loadType()
        guard address == wallet.address else { throw TOSPQError.keyBinding }
        for _ in 0..<2 {
            let count = Int(try s.loadUint(bits: 3))
            guard count < 7 else { throw TOSPQError.invalidInput }
            try s.skip(count * 8)
        }
        switch try s.loadUint(bits: 3) {
        case 0: break
        case 1: try s.skip(256)
        default: throw TOSPQError.invalidInput
        }
        func coins() throws -> BigUInt {
            let count = Int(try s.loadUint(bits: 4))
            return count == 0 ? 0 : BigUInt(try s.loadBytes(count))
        }
        let lastPaid = UInt32(try s.loadUint(bits: 32))
        let debt = try s.loadBoolean() ? coins() : BigUInt(0)
        try s.skip(64)
        let balance = try coins()
        if try s.loadBoolean() { _ = try s.loadRef() }
        if try s.loadBoolean() {
            let active = try TOSQuantumAccountState.snapshot(boc, expectedAddress: wallet.address, expectedCode: wallet.code)
            let state = try wallet.readState(account: address, code: wallet.code, data: active.data)
            return Snapshot(status: .active(state), balance: active.balance, storageDebt: active.storageDebt, lastPaid: active.lastPaid)
        }
        let status: Status = try s.loadBoolean() ? .frozen(s.loadBytes(32)) : .uninitialized
        try s.endParse()
        return Snapshot(status: status, balance: balance, storageDebt: debt, lastPaid: lastPaid)
    }
}
