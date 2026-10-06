import Foundation
import BigInt
import TonSwift
import CoreComponents

public enum TOSV5R2FeeClass: UInt8 {
    case rescueAuth = 1, pop = 2, prepare = 3
    fileprivate var format: (submission: UInt64, request: UInt64, bits: Int, refs: Int) {
        switch self {
        case .rescueAuth: return (0x53554233, 0x41553252, 1019, 1)
        case .pop: return (0x50505333, 0x504f5033, 616, 2)
        case .prepare: return (0x46505233, 0x50525033, 875, 1)
        }
    }
}
/// Fee framing only. Durable reservation, signature verification/cache and live admission checks are separate requirements.
public struct TOSV5R2Fee {
    public let intent: Cell, digest: Data, leaf: UInt32
    public init(vault: Address, configHash: Data, epoch0: UInt32, leaf: UInt32, validUntil: UInt32,
                value: BigUInt, kind: TOSV5R2FeeClass, payload: Cell, provenTime: UInt32) throws {
        try Self.validatePayload(kind: kind, payload: payload)
        guard vault.workchain == 0, configHash.count == 32, validUntil > provenTime,
              UInt64(validUntil) - UInt64(provenTime) <= 3600, provenTime >= epoch0,
              leaf < 1 << 20, leaf / 4 == (provenTime - epoch0) / 3600,
              value > 0, value.bitWidth <= 120 else { throw TOSPQError.invalidInput }
        let n = (value.bitWidth + 7) / 8
        let cell = try Builder().store(uint: 0x46454534, bits: 32).store(data: Data("TOS-RESCUE-FEE-v1".utf8))
            .store(uint: kind.rawValue, bits: 8).store(vault).store(data: configHash).store(uint: leaf, bits: 32)
            .store(uint: validUntil, bits: 32).store(uint: n, bits: 4).store(biguint: value, bits: n * 8).store(ref: payload).endCell()
        self.leaf = leaf; intent = cell; digest = cell.hash()
    }
    public func external(signature: Data) throws -> Cell {
        guard signature.count == 2832 else { throw TOSPQError.invalidInput }
        func word(_ offset: Int) -> UInt32 {
            let start = signature.index(signature.startIndex, offsetBy: offset)
            let end = signature.index(start, offsetBy: 4)
            return signature[start..<end].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        guard word(0) == 0, word(4) == leaf, word(8) == 3, word(2188) == 8 else { throw TOSPQError.invalidInput }
        return try Builder().store(ref: intent).store(ref: TOSPQWallet.byteChain(Data(Array(signature)))).endCell()
    }
    public static func validatePayload(kind: TOSV5R2FeeClass, payload: Cell) throws {
        guard !payload.isExotic, payload.level == 0 else { throw TOSPQError.invalidInput }
        let s = try payload.beginParse(), format = kind.format
        guard s.remainingBits == 32, s.remainingRefs == 2, try s.loadUint(bits: 32) == format.submission else { throw TOSPQError.invalidInput }
        let request = try s.loadRef()
        guard !request.isExotic, request.level == 0 else { throw TOSPQError.invalidInput }
        let r = try request.beginParse()
        guard r.remainingBits == format.bits, r.remainingRefs == format.refs, try r.loadUint(bits: 32) == format.request else { throw TOSPQError.invalidInput }
        if kind == .rescueAuth {
            _ = try r.loadBits(811)
            guard try r.loadUint(bits: 8) == 2 else { throw TOSPQError.invalidInput }
        }
    }
}
