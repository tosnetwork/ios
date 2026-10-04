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
        walletCode = try Cell.fromBoc(src: Data(hex: Self.walletCodeHex)!)[0]
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
    private static let walletCodeHex = "b5ee9c72410225010007e2000114ff00f4a413f4bcf2c80b01020120020302014804050124f220d70b1f82107369676ebaf2e08a7f8ad81c0202cc0607020120121302b5d90e8698180b8d8492f81c7a690eba4e090492f81f010eb858f90410820aaaa245d4c9836097d201800f807701890410832bc3a375e90c10839b4b73a5ed8492f81f0410832bc3a375d718118906ba4c081505cc8987038456c714081c04f7bdda89a10083ae43ae17ffda89a1020283ae43e8086241ae9523a924da03c5a2a82647021c21b6784380031e9a63b67841a1ae160380071d0603b6792263c4ffda89a1a401a63f020241ae31e80860093443083f75e5ae24034803bc49a1ae160384032cd844e0da8267bc05919401963e039e2de8019993daa9c067090a0d0b019aed44d0810141d721f4043120d74a91d4926d01e2d16ef2e70f8020d72101d074d721fa4030fa44f828fa443058bd915be0ed44d0810141d721f4058307f40e6fa1319130e18040d721707fdb3c1e01f404206e9530705470008e14d0d301d33fd33fd3ffd123c20024c104b0f2e70ee223c300f2e7080620d74981010bba21d74ac000b0f2e71120d70b02c004f2e711fa44f828fa445033ba5213bd12b0f2e71126baf2e70804d31f01821041555448baf2e713d4f404d121d0d21ff83512baf2e709fa40f82812c7050c01e401206e9530705470008e14d0d301d33fd33fd3ffd123c20024c104b0f2e70ee25b02d0d301fa40d121c20022c104b0f2e70e02c20121c001b0f2d70e22843fbaf2d71202a4700220d74981010bba21d74ac000b0f2e71120d70b02c004f2e711fa44f828fa445033ba5213bd12b0f2e711120f01fcc000f2e713017f21d73930709421c700b38e2d01d72820761e436c20d749c008f2e09320d74ac002f2e09320d71d06c712c2005230b0f2d089d74cd7393001a4e86c128407bbf2e093d74ac000f2e09320d09420c700b38e21d72820761e436cd30721802cb0c300f2d713018100c0b08100c0baf2d713d430d0e830017f1102ecf2e70ad33f5114baf2e70bd33f5117baf2e70c26843fbaf2d712d31f21f823bcf823500ba012bb19b0f2e70d07d307d4d124c0038eb225db3c286ef2d71008d020d7498308ba21d74ac000b0f2e710028230544f532d41555448c8cb3fccc9f9004005f910f2e710973234066ef2e710e203a44303040d0e01f4208407b0807fb021ab0784efb022abf702c07f0184efbab0018100edbeb0f2d7102083f7baf2d7102082f0c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037abaf2d710208306baf2d7102082f026e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05ba10001a03c8cb0112cb3fcb3fcbffc902001803c8cb0112cb3fcb3fcbffc900faf2d7102082f0ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7fbaf2d7102082f026e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85baf2d71020c000f2d71082f0c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fabaf2d7100078ed44d0d200d31f810120d718f40430049a21841fbaf2d71201a401de24d0d70b01c201966c22706d4133de02c8ca00cb1f01cf16f400ccc9ed54ed5502012014150019be5f0f6a2684080a0eb90fa02c02012016170201481a1b006db7f5dda89a1020283ae43e8086241ae9523a924da03c5a240dd2a60e0a8e0011c29a1a603a67fa67fa7ffa247840049820961e5ce1dc5002015818190019adce76a2684020eb90eb85ffc00019af1df6a2684010eb90eb858fc00017b325fb51341c75c875c2c7e00011b262fb513435c2802001feeda2edfbed44d0810141d721f4043120d74a91d4926d01e2d1206e913099d0d70b01c201f2d70fe2218308d722028308d723208020d721d21ff83512baf2e094d31fd31fd31fed44d0d200d31f20d31fd3ffd70a000af90140ccf9109a28945f0adb31e1f2c087df02b35007b0f2d0845125baf2e0855036baf2e086f823bb1d014af2d08821841fbaf2d0852292f800de01a47fc8ca00cb1f01cf16c9ed542092f80fde70db3c1e03f6eda2edfb02f404216e91328e4d521321d73930709421c700b38e2d01d72820761e436c20d749c008f2e09320d74ac002f2e09320d71d06c712c2005230b0f2d089d74cd7393001a4e86c128407bbf2e093d74ac000f2e093ed55e201d20001c000925f03e020d70b07c005e30231ebd72c0814209170e30e5210b11f2021014c016eb312b1f2d71378d721d33ffa40d1ed44d0810141d721f4043120d74a91d4926d01e2d15922000c01d72c081c1201908e3930d72c08248e2d21f2e092d200ed44d0d2005113baf2d08f54503091319c01810140d721d70a00f2e08ee2c8ca0058cf16c9ed5493f2c08de2e30d20d74a935bdb31e1d74cd02401e202206e9530705470008e14d0d301d33fd33fd3ffd123c20024c104b0f2e70ee25b01c201f2d70f66baf2e70b20843fbaf2d7127101a4700320d74981010bba21d74ac000b0f2e71120d70b02c004f2e711fa44f828fa445033ba5213bd12b0f2e711413003c8cb0112cb3fcb3fcbffc970230074ed44d0d200d31f810120d718f40430049a21841fbaf2d71201a401de24d0d70b01c201966c22706d4133de02c8ca00cb1f01cf16f400ccc9ed54009801fa4001fa44f828fa443058baf2e091ed44d0810141d718f404059d7fc8ca0040338307f453f2e08b8e14128307f45bf2e08c21d70a00216e01b3b0f2d090e2c858cf16f40058cf16c9ed54c7bcc44c"
}
