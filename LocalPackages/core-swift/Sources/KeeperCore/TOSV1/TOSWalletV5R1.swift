import Foundation
import TonSwift

/// TOS V5 uses a plain subwallet ID and signs the network ID separately.
/// Compiled code: tosnetwork/tos sdk/js/packages/wallets/src/codes.ts,
/// revision ee5ad71c343eb2227a8bd42d57bea259da4da0ec; code hash
/// 086a86aa9913c0ec52277adbb7e4b5695964dbb8c817ad0c305cdd345bbfac69.
public struct TOSWalletV5R1: WalletContract {
    public let workchain: Int8
    public let stateInit: StateInit
    public let code: Cell
    public let networkGlobalId: Int32
    public let subwalletId: UInt32
    public let maxMessages = 255

    public init(publicKey: Data, networkGlobalId: Int32, workchain: Int8 = 0, subwalletId: UInt32 = 0) throws {
        guard publicKey.count == 32 else { throw TonError.custom("Expected a 32-byte Ed25519 public key") }
        let code = try Cell.fromBoc(src: Data(hex: Self.codeBOCHex)!)[0]
        let data = try Builder()
            .store(bit: true)
            .store(uint: 0, bits: 32)
            .store(uint: subwalletId, bits: 32)
            .store(data: publicKey)
            .store(bit: false)
            .endCell()
        self.code = code
        self.workchain = workchain
        self.networkGlobalId = networkGlobalId
        self.subwalletId = subwalletId
        let initCell = try Builder()
            .store(bit: false) // split_depth absent
            .store(bit: false) // special absent
            .storeMaybe(ref: code)
            .storeMaybe(ref: data)
            .store(bit: false) // empty library dictionary
            .endCell()
        self.stateInit = try initCell.beginParse().loadType()
    }

    public func createTransfer(args: WalletTransferData, messageType: MessageType = .ext) throws -> WalletTransfer {
        guard args.messages.count <= maxMessages, args.seqno <= UInt32.max else {
            throw TonError.custom("Invalid TOS V5 message count or sequence number")
        }
        let validUntil = args.timeout ?? (UInt64(Date().timeIntervalSince1970) + 60)
        guard validUntil <= UInt32.max else { throw TonError.custom("Invalid TOS V5 expiration time") }
        var actions = Builder()
        for message in args.messages {
            actions = try Builder()
                .store(uint: 0x0ec3c86d, bits: 32)
                .store(uint: args.sendMode.rawValue, bits: 8)
                .store(ref: actions)
                .store(ref: Builder().store(message))
        }
        let signingMessage = try Builder()
            .store(uint: messageType == .ext ? 0x7369676e : 0x73696e74, bits: 32)
            .store(int: networkGlobalId, bits: 32)
            .store(uint: subwalletId, bits: 32)
            .store(uint: validUntil, bits: 32)
            .store(uint: args.seqno, bits: 32)
            .storeMaybe(ref: args.messages.isEmpty ? nil : actions)
            .store(bit: false)
        return WalletTransfer(signingMessage: signingMessage, signaturePosition: .tail)
    }

    private static let codeBOCHex = "b5ee9c72410225010007e2000114ff00f4a413f4bcf2c80b01020120020302014804050124f220d70b1f82107369676ebaf2e08a7f8ad81c0202cc0607020120121302b5d90e8698180b8d8492f81c7a690eba4e090492f81f010eb858f90410820aaaa245d4c9836097d201800f807701890410832bc3a375e90c10839b4b73a5ed8492f81f0410832bc3a375d718118906ba4c081505cc8987038456c714081c04f7bdda89a10083ae43ae17ffda89a1020283ae43e8086241ae9523a924da03c5a2a82647021c21b6784380031e9a63b67841a1ae160380071d0603b6792263c4ffda89a1a401a63f020241ae31e80860093443083f75e5ae24034803bc49a1ae160384032cd844e0da8267bc05919401963e039e2de8019993daa9c067090a0d0b019aed44d0810141d721f4043120d74a91d4926d01e2d16ef2e70f8020d72101d074d721fa4030fa44f828fa443058bd915be0ed44d0810141d721f4058307f40e6fa1319130e18040d721707fdb3c1e01f404206e9530705470008e14d0d301d33fd33fd3ffd123c20024c104b0f2e70ee223c300f2e7080620d74981010bba21d74ac000b0f2e71120d70b02c004f2e711fa44f828fa445033ba5213bd12b0f2e71126baf2e70804d31f01821041555448baf2e713d4f404d121d0d21ff83512baf2e709fa40f82812c7050c01e401206e9530705470008e14d0d301d33fd33fd3ffd123c20024c104b0f2e70ee25b02d0d301fa40d121c20022c104b0f2e70e02c20121c001b0f2d70e22843fbaf2d71202a4700220d74981010bba21d74ac000b0f2e71120d70b02c004f2e711fa44f828fa445033ba5213bd12b0f2e711120f01fcc000f2e713017f21d73930709421c700b38e2d01d72820761e436c20d749c008f2e09320d74ac002f2e09320d71d06c712c2005230b0f2d089d74cd7393001a4e86c128407bbf2e093d74ac000f2e09320d09420c700b38e21d72820761e436cd30721802cb0c300f2d713018100c0b08100c0baf2d713d430d0e830017f1102ecf2e70ad33f5114baf2e70bd33f5117baf2e70c26843fbaf2d712d31f21f823bcf823500ba012bb19b0f2e70d07d307d4d124c0038eb225db3c286ef2d71008d020d7498308ba21d74ac000b0f2e710028230544f532d41555448c8cb3fccc9f9004005f910f2e710973234066ef2e710e203a44303040d0e01f4208407b0807fb021ab0784efb022abf702c07f0184efbab0018100edbeb0f2d7102083f7baf2d7102082f0c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037abaf2d710208306baf2d7102082f026e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05ba10001a03c8cb0112cb3fcb3fcbffc902001803c8cb0112cb3fcb3fcbffc900faf2d7102082f0ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7fbaf2d7102082f026e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85baf2d71020c000f2d71082f0c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fabaf2d7100078ed44d0d200d31f810120d718f40430049a21841fbaf2d71201a401de24d0d70b01c201966c22706d4133de02c8ca00cb1f01cf16f400ccc9ed54ed5502012014150019be5f0f6a2684080a0eb90fa02c02012016170201481a1b006db7f5dda89a1020283ae43e8086241ae9523a924da03c5a240dd2a60e0a8e0011c29a1a603a67fa67fa7ffa247840049820961e5ce1dc5002015818190019adce76a2684020eb90eb85ffc00019af1df6a2684010eb90eb858fc00017b325fb51341c75c875c2c7e00011b262fb513435c2802001feeda2edfbed44d0810141d721f4043120d74a91d4926d01e2d1206e913099d0d70b01c201f2d70fe2218308d722028308d723208020d721d21ff83512baf2e094d31fd31fd31fed44d0d200d31f20d31fd3ffd70a000af90140ccf9109a28945f0adb31e1f2c087df02b35007b0f2d0845125baf2e0855036baf2e086f823bb1d014af2d08821841fbaf2d0852292f800de01a47fc8ca00cb1f01cf16c9ed542092f80fde70db3c1e03f6eda2edfb02f404216e91328e4d521321d73930709421c700b38e2d01d72820761e436c20d749c008f2e09320d74ac002f2e09320d71d06c712c2005230b0f2d089d74cd7393001a4e86c128407bbf2e093d74ac000f2e093ed55e201d20001c000925f03e020d70b07c005e30231ebd72c0814209170e30e5210b11f2021014c016eb312b1f2d71378d721d33ffa40d1ed44d0810141d721f4043120d74a91d4926d01e2d15922000c01d72c081c1201908e3930d72c08248e2d21f2e092d200ed44d0d2005113baf2d08f54503091319c01810140d721d70a00f2e08ee2c8ca0058cf16c9ed5493f2c08de2e30d20d74a935bdb31e1d74cd02401e202206e9530705470008e14d0d301d33fd33fd3ffd123c20024c104b0f2e70ee25b01c201f2d70f66baf2e70b20843fbaf2d7127101a4700320d74981010bba21d74ac000b0f2e71120d70b02c004f2e711fa44f828fa445033ba5213bd12b0f2e711413003c8cb0112cb3fcb3fcbffc970230074ed44d0d200d31f810120d718f40430049a21841fbaf2d71201a401de24d0d70b01c201966c22706d4133de02c8ca00cb1f01cf16f400ccc9ed54009801fa4001fa44f828fa443058baf2e091ed44d0810141d718f404059d7fc8ca0040338307f453f2e08b8e14128307f45bf2e08c21d70a00216e01b3b0f2d090e2c858cf16f40058cf16c9ed54c7bcc44c"
}
