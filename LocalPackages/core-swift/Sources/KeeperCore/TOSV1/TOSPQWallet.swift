import Foundation
import TonSwift
import CoreComponents

/// A strict module-only PQ-from-genesis account. A funded transport is required.
public struct TOSPQWallet {
    public let algorithm: TOSPQAlgorithm
    public let publicKey: Data
    public let network: Int32
    public let workchain: Int8
    public let moduleCode: Cell
    public let moduleData: Cell
    public let moduleStateInit: Cell
    public let moduleAddress: Address
    public let walletCode: Cell
    public let walletData: Cell
    public let walletStateInit: Cell
    public let address: Address
    public init(algorithm: TOSPQAlgorithm, publicKey: Data, network: Int32, workchain: Int8 = 0) throws {
        guard publicKey.count == algorithm.publicKeySize else { throw TOSPQError.invalidInput }
        self.algorithm = algorithm; self.publicKey = publicKey; self.network = network; self.workchain = workchain
        moduleCode = try Cell.fromBoc(src: Data(hex: algorithm == .mldsa44 ? Self.mldsaCode : Self.falconCode)!)[0]
        walletCode = try Cell.fromBoc(src: Data(hex: TOSWalletV5R1.codeBOCHex)!)[0]
        let b = try Builder().store(int: network, bits: 32)
        if algorithm == .falcon512Padded { try b.store(uint: 1, bits: 16) }
        moduleData = try b.store(ref: Self.byteChain(publicKey)).endCell()
        moduleStateInit = try Self.stateInit(code: moduleCode, data: moduleData)
        moduleAddress = Address(workchain: workchain, hash: moduleStateInit.hash())
        let auth = try Builder().store(uint: 2, bits: 2).store(uint: 0, bits: 64).store(uint: 0, bits: 64)
            .store(data: moduleAddress.hash).endCell()
        walletData = try Builder().store(bit: false).store(uint: 0, bits: 32).store(uint: 0, bits: 32)
            .store(data: Data(count: 32)).store(bit: false).store(ref: auth).endCell()
        walletStateInit = try Self.stateInit(code: walletCode, data: walletData)
        address = Address(workchain: workchain, hash: walletStateInit.hash())
    }
    public func transferPayload(destination: Address, nanotomi: UInt64, comment: String = "") throws -> Cell {
        guard destination.hash.count == 32, nanotomi > 0, nanotomi <= UInt64(Int64.max),
              comment.utf8.count <= 4096 else { throw TOSPQError.invalidInput }
        let body = comment.isEmpty ? try Builder().endCell() : try Self.byteChain(Data(count: 4) + Data(comment.utf8))
        let b = try Builder().store(uint: 4, bits: 4).store(uint: 0, bits: 2).store(destination)
        let coinBytes = (64 - nanotomi.leadingZeroBitCount + 7) / 8
        try b.store(uint: coinBytes, bits: 4).store(uint: nanotomi, bits: coinBytes * 8)
        let msg = try b.store(bit: false).store(uint: 0, bits: 4).store(uint: 0, bits: 4)
            .store(uint: 0, bits: 64).store(uint: 0, bits: 32).store(bit: false).store(bit: true).store(ref: body).endCell()
        return try Builder().store(uint: 0x0ec3c86d, bits: 32).store(uint: 3, bits: 8)
            .store(ref: Builder().endCell()).store(ref: msg).endCell()
    }
    public func request(epoch: UInt64, nonce: UInt64, validUntil: UInt32, now: UInt32, payload: Cell) throws -> Cell {
        guard validUntil > now, UInt64(validUntil) <= UInt64(now) + 3600,
              epoch < UInt64.max, nonce < UInt64.max else { throw TOSPQError.invalidInput }
        return try Builder().store(int: network, bits: 32).store(address).store(uint: epoch, bits: 64)
            .store(uint: nonce, bits: 64).store(uint: validUntil, bits: 32).store(uint: 0, bits: 8)
            .store(ref: payload).endCell()
    }
    public func signingMessage(request: Cell) throws -> Data {
        let digest = try Builder().store(data: Data("TOS-AUTH".utf8)).store(ref: request).endCell().hash()
        if algorithm == .mldsa44 { return digest }
        var wc = Int32(workchain).bigEndian
        return Data("TOS-AUTH-FALCON512-PADDED-v1".utf8) + Data([0]) +
            withUnsafeBytes(of: &wc) { Data($0) } + moduleAddress.hash + digest
    }
    public func submission(request: Cell, signature: Data, queryId: UInt64 = 0) throws -> Cell {
        guard signature.count == algorithm.signatureSize else { throw TOSPQError.invalidInput }
        let envelope = try Builder().store(uint: 0x41555448, bits: 32).store(ref: request).store(bit: false).endCell()
        return try Builder().store(uint: algorithm == .mldsa44 ? 0x4d4c4434 : 0x46414c31, bits: 32)
            .store(uint: queryId, bits: 64).store(ref: envelope).store(ref: Self.byteChain(signature)).endCell()
    }
    public func authCounters(code: Cell, data: Cell) throws -> (epoch: UInt64, nonce: UInt64) {
        guard code.hash() == walletCode.hash() else { throw TOSPQError.keyBinding }
        let s = try data.beginParse()
        guard (try s.loadBoolean()) == false else { throw TOSPQError.keyBinding }
        _ = try s.loadUint(bits: 32)
        guard try s.loadUint(bits: 32) == 0, (try s.loadBytes(32)) == Data(count: 32),
              (try s.loadBoolean()) == false else { throw TOSPQError.keyBinding }
        let a = try s.loadRef().beginParse()
        guard s.remainingBits == 0, s.remainingRefs == 0, try a.loadUint(bits: 2) == 2 else { throw TOSPQError.keyBinding }
        let epoch = try a.loadUint(bits: 64), nonce = try a.loadUint(bits: 64)
        guard try a.loadBytes(32) == moduleAddress.hash, a.remainingBits == 0, a.remainingRefs == 0 else { throw TOSPQError.keyBinding }
        return (epoch, nonce)
    }
    public static func byteChain(_ data: Data) throws -> Cell {
        guard !data.isEmpty else { throw TOSPQError.invalidInput }
        var tail: Cell?
        let parts = stride(from: 0, to: data.count, by: 127).map { data.subdata(in: $0..<min($0+127, data.count)) }
        for part in parts.reversed() {
            let b = try Builder().store(data: part)
            if let next = tail { try b.store(ref: next) }
            tail = try b.endCell()
        }
        guard let tail else { throw TOSPQError.invalidInput }; return tail
    }
    private static func stateInit(code: Cell, data: Cell) throws -> Cell {
        try Builder().store(bit: false).store(bit: false).storeMaybe(ref: code).storeMaybe(ref: data)
            .store(bit: false).endCell()
    }
    private static let mldsaCode = "b5ee9c7241020801000151000114ff00f4a413f4bcf2c80b0102012002030201480405000af230f2c76c01e6d001d0d70b0371b0925f03e020d749c120925f03e020d70b1f82104d4c4434bd925f03e0d31f31d33f31d4d4d1ed44d0d21fd4d1f8355220baf2e70923d0d31f01821041555448baf2e713d4f404d1206e91308e10d020d7498308ba01d74ac000b0f2e710e220d0d21f04baf2e70902fa4021060013a1273bda89a1a43fa9a301fe20d74981010bba21d74ac000b0f2e71120d70b02c004f2e711fa44f828fa445033ba5213bd12b0f2e71130d33f31d33f31d31f21f823bcf823810e10a013bb12b0f2e70dd30701c103f2e713d431d1028230544f532d41555448c8cb3fccc9f900c8cbffc98298544f532d415554482d4d4c2d4453412d34342d7631c8cba707005ac95a14f93100f2e710037003a112b60972fb0271708018c8cb055004cf1623fa0213cb6912cb00ccc98040fb00afa7c4cb"
    private static let falconCode = "b5ee9c724102080100016e000114ff00f4a413f4bcf2c80b0102012002030201480405000af230f2c76c01f6d001d0d70b0371b0925f03e020d749c120925f03e020d70b1f821046414c31bd925f03e0d31f31d33f31d4d4d1ed44d0d21fd30f01c001f2e713d4d1f8355220baf2e70923d0d31f01821041555448baf2e713d4f404d1206e91308e10d020d7498308ba01d74ac000b0f2e710e220d0d21f04baf2e70902fa4021060017a02c1fda89a1a43fa61fa9a301cc20d74981010bba21d74ac000b0f2e71120d70b02c004f2e711fa44f828fa445033ba5213bd12b0f2e71130d33f31d33f31d31f21f823bcf823810e10a013bb12b0f2e70dd30701c103f2e713d431d1f828fa44048230544f532d41555448c8cb3fccc9f900700700b282d0544f532d415554482d46414c434f4e3531322d5041444445442d7631c8cbdfcb0712ca1f14cbff13cbffc94033f93101f2e710037003a112b60972fb0271708018c8cb055004cf1623fa0213cb6912cb00ccc98040fb00b8d77e97"
}
