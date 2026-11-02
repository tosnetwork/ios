import Foundation
import BigInt
import TonSwift
import CoreComponents

/// Exact Token request, not proof of funds or a signing capability.
/// Precision is persisted for review; raw integer units are the onchain amount.
public struct TOSQuantumTokenTransferIntent: Codable, Equatable {
    public let owner: Address
    public let master: Address
    public let wallet: Address
    public let recipient: Address
    public let units: BigUInt
    public let decimals: Int
    public let queryId: UInt64
    public let attachedTos: BigUInt
    public let forwardTos: BigUInt

    public init(owner: Address, master: Address, wallet: Address, recipient: Address, units: BigUInt,
                decimals: Int, queryId: UInt64, attachedTos: BigUInt, forwardTos: BigUInt = 0) throws {
        guard [owner, master, wallet, recipient].allSatisfy({ $0.workchain == 0 && $0.hash.count == 32 }),
              units > 0, units.bitWidth <= 120, (0...255).contains(decimals),
              attachedTos > 0, attachedTos.bitWidth <= 120, forwardTos < attachedTos else { throw TOSPQError.invalidInput }
        _ = try TOSTokenContractCodes.family(owner: owner, master: master, wallet: wallet)
        self.owner = owner; self.master = master; self.wallet = wallet; self.recipient = recipient
        self.units = units; self.decimals = decimals; self.queryId = queryId
        self.attachedTos = attachedTos; self.forwardTos = forwardTos
    }

    public func body() throws -> Cell {
        try Builder().store(JettonTransferData(queryId: queryId, amount: units, toAddress: recipient,
            responseAddress: owner, forwardAmount: forwardTos, forwardPayload: nil)).endCell()
    }
    public func message() throws -> Cell {
        try Builder().store(MessageRelaxed.internal(to: wallet, value: attachedTos, bounce: true, body: body())).endCell()
    }
    public func actions() throws -> Cell {
        try Builder().store(uint: 0x0ec3c86d, bits: 32).store(uint: 3, bits: 8)
            .store(ref: Builder().endCell()).store(ref: message()).endCell()
    }

    private enum CodingKeys: String, CodingKey { case version, owner, master, wallet, recipient, units, decimals, queryId, attachedTos, forwardTos }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(UInt8.self, forKey: .version) == 1 else { throw TOSPQError.invalidInput }
        func address(_ key: CodingKeys) throws -> Address {
            let value = try c.decode(String.self, forKey: key)
            guard value.range(of: "^0:[0-9a-f]{64}$", options: .regularExpression) != nil else { throw TOSPQError.invalidInput }
            return try Address.parse(value)
        }
        func amount(_ key: CodingKeys, limit: Int) throws -> BigUInt {
            let value = try c.decode(String.self, forKey: key)
            guard (1...limit).contains(value.utf8.count), let number = BigUInt(value), String(number) == value else { throw TOSPQError.invalidInput }
            return number
        }
        let query = try amount(.queryId, limit: 20)
        guard let queryId = UInt64(exactly: query) else { throw TOSPQError.invalidInput }
        try self.init(owner: address(.owner), master: address(.master), wallet: address(.wallet), recipient: address(.recipient),
            units: amount(.units, limit: 37), decimals: c.decode(Int.self, forKey: .decimals), queryId: queryId,
            attachedTos: amount(.attachedTos, limit: 37), forwardTos: amount(.forwardTos, limit: 37))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(UInt8(1), forKey: .version)
        try c.encode(owner.toRaw(), forKey: .owner); try c.encode(master.toRaw(), forKey: .master)
        try c.encode(wallet.toRaw(), forKey: .wallet); try c.encode(recipient.toRaw(), forKey: .recipient)
        try c.encode(String(units), forKey: .units); try c.encode(decimals, forKey: .decimals)
        try c.encode(String(queryId), forKey: .queryId); try c.encode(String(attachedTos), forKey: .attachedTos)
        try c.encode(String(forwardTos), forKey: .forwardTos)
    }
}
