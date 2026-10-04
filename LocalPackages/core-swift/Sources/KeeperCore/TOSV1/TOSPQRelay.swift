import Foundation
import TonSwift
import CoreComponents

/// Builds only the deployment and AUTH transport reviewed by the PQ wallet screen.
/// The fee wallet authorizes this transport; the PQ signature alone authorizes spending.
public struct TOSPQRelayPlan {
    public let messages: [Cell]
    fileprivate let account: Address
    fileprivate init(messages: [Cell], account: Address) { self.messages = messages; self.account = account }
}
public struct TOSPQRelay {
    public let wallet: TOSPQWallet
    public init(wallet: TOSPQWallet) { self.wallet = wallet }
    public func deployment(moduleFunding: UInt64, walletFunding: UInt64) throws -> TOSPQRelayPlan {
        TOSPQRelayPlan(messages: [try message(to: wallet.moduleAddress, value: moduleFunding, initCell: wallet.moduleStateInit, body: Builder().endCell()),
         try message(to: wallet.address, value: walletFunding, initCell: wallet.walletStateInit, body: Builder().endCell())], account: wallet.address)
    }
    public func submission(request: Cell, signature: Data, funding: UInt64) throws -> TOSPQRelayPlan {
        let s = try request.beginParse()
        let network = try s.loadInt(bits: 32)
        let target: Address = try s.loadType()
        guard network == Int(wallet.network), target == wallet.address else { throw TOSPQError.keyBinding }
        _ = try s.loadUint(bits: 64); _ = try s.loadUint(bits: 64); _ = try s.loadUint(bits: 32)
        guard try s.loadUint(bits: 8) == 0, s.remainingBits == 0, s.remainingRefs == 1 else { throw TOSPQError.invalidInput }
        guard TOSPQSigner.verify(algorithm: wallet.algorithm, publicKey: wallet.publicKey,
            message: try wallet.signingMessage(request: request), signature: signature) else { throw TOSPQError.signingFailure }
        return TOSPQRelayPlan(messages: [try message(to: wallet.moduleAddress, value: funding, initCell: nil,
            body: wallet.submission(request: request, signature: signature))], account: wallet.address)
    }
    public func feeSigningMessage(plan: TOSPQRelayPlan, network: Int32, seqno: UInt32,
                                  now: UInt32, validUntil: UInt32) throws -> Cell {
        guard network == wallet.network, plan.account == wallet.address, (1...2).contains(plan.messages.count), validUntil > now,
              UInt64(validUntil) <= UInt64(now) + 600 else { throw TOSPQError.invalidInput }
        var actions = try Builder().endCell()
        for raw in plan.messages {
            actions = try Builder().store(uint: 0x0ec3c86d, bits: 32).store(uint: 3, bits: 8)
                .store(ref: actions).store(ref: raw).endCell()
        }
        return try Builder().store(uint: 0x7369676e, bits: 32).store(int: network, bits: 32)
            .store(uint: 0, bits: 32).store(uint: validUntil, bits: 32).store(uint: seqno, bits: 32)
            .store(bit: true).store(ref: actions).store(bit: false).endCell()
    }
    private func message(to: Address, value: UInt64, initCell: Cell?, body: Cell) throws -> Cell {
        guard value > 0, value <= UInt64(Int64.max) else { throw TOSPQError.invalidInput }
        let b = try Builder().store(uint: 4, bits: 4).store(uint: 0, bits: 2).store(to)
        let count = (64 - value.leadingZeroBitCount + 7) / 8
        try b.store(uint: count, bits: 4).store(uint: value, bits: count * 8)
            .store(bit: false).store(uint: 0, bits: 4).store(uint: 0, bits: 4)
            .store(uint: 0, bits: 64).store(uint: 0, bits: 32)
        if let initCell { try b.store(bit: true).store(bit: true).store(ref: initCell) }
        else { try b.store(bit: false) }
        return try b.store(bit: true).store(ref: body).endCell()
    }

}
