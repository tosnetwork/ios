import Foundation
import TonSwift

/// TOS V5 uses a plain subwallet ID and signs the network ID separately.
/// Compiled code: tosnetwork/tos sdk/js/packages/wallets/src/codes.ts,
/// revision 1cef5d3ecddb874f36b027b5eebb9918e34a8cdf; code hash
/// 70cac370905beb6fa644922253f7d74335c479fa1e4d9dc8bf519c71e0f8c031.
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

    /// Shared with TOSPQWallet, whose module-only account runs the same code.
    static let codeBOCHex = "b5ee9c7241022801000937000114ff00f4a413f4bcf2c80b01020120020302014804050124f220d70b1f82107369676ebaf2e08a7f8ad81e0202cb0607020120141502b5d087434c0c05c6c2497c0e3d34875d270482497c0f80875c2c7c82084105555122ea64c1b04be900c007c04780c482084195e1d1baf4860841cda5b9d2f6c2497c0f82084195e1d1baeb8c08c4835d26040a82e644c381c22b638a081e04f9a0f6a2684020eb90eb85fff6a2684080a0eb90fa0218906ba548ea493680f168aa0991c087086d9e10e000c7a698ed9e10686b8580e001c74180ed9e4898f13ff6a2686900698fc080906b8c7a0218024d10c20fdd796b8900d200ef12686b8580e100cb36113836a099ef01646500658f80e78b7a006664f6aa7019c0090a0d0b019aed44d0810141d721f4043120d74a91d4926d01e2d16ef2e70f8020d72101d074d721fa4030fa44f828fa443058bd915be0ed44d0810141d721f4058307f40e6fa1319130e18040d721707fdb3c2201f404206e9530705470008e14d0d301d33fd33fd3ffd123c20024c104b0f2e70ee223c300f2e7080620d74981010bba21d74ac000b0f2e71120d70b02c004f2e711fa44f828fa445033ba5213bd12b0f2e71126baf2e70804d31f01821041555448baf2e713d4f404d121d0d21ff83512baf2e709fa40f82812c7050c01e401206e9530705470008e14d0d301d33fd33fd3ffd123c20024c104b0f2e70ee25b02d0d301fa40d121c20022c104b0f2e70e02c20121c001b0f2d70e22843fbaf2d71202a4700220d74981010bba21d74ac000b0f2e71120d70b02c004f2e711fa44f828fa445033ba5213bd12b0f2e711120f02fcc000f2e713017f21d73930709421c700b38e4f01d72820761e436c20d749c008f2e09320d74ac002f2e093228e2c20d71d06c712c200f2d08920d70b077cb08e1820d74dd7393020d749c10292307095d70b01c003e2f2d093deded74cd7393001a4e86c128407bbf2e093d74ac000f2e09320d09420c700b38ae830017f121302ecf2e70ad33f5114baf2e70bd33f5117baf2e70c26843fbaf2d712d31f21f823bcf823500ba012bb19b0f2e70d07d307d4d124c0038eb225db3c286ef2d71008d020d7498308ba21d74ac000b0f2e710028230544f532d41555448c8cb3fccc9f9004005f910f2e710973234066ef2e710e203a44303040d0e01f4208407b0807fb021ab0784efb022abf702c07f0184efbab0018100edbeb0f2d7102083f7baf2d7102082f0c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037abaf2d710208306baf2d7102082f026e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05ba10001a03c8cb0112cb3fcb3fcbffc902001803c8cb0112cb3fcb3fcbffc901fef2d7102082f0ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7fbaf2d7102082f026e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85baf2d71020c000f2d7102082f0c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fabaf2d7102011009682e900000000000000000000000000000000000000000000000000000000000080baf2d71082f0ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffbaf2d7100042d72820761e436cd30721802cb0c300f2d713018100c0b08100c0baf2d713d430d00078ed44d0d200d31f810120d718f40430049a21841fbaf2d71201a401de24d0d70b01c201966c22706d4133de02c8ca00cb1f01cf16f400ccc9ed54ed5502012016170019be5f0f6a2684080a0eb90fa02c02012018190201481c1d006db7f5dda89a1020283ae43e8086241ae9523a924da03c5a240dd2a60e0a8e0011c29a1a603a67fa67fa7ffa247840049820961e5ce1dc500201581a1b0019adce76a2684020eb90eb85ffc00019af1df6a2684010eb90eb858fc00017b325fb51341c75c875c2c7e00011b262fb513435c2802002feeda2edfbed44d0810141d721f4043120d74a91d4926d01e2d1206e913099d0d70b01c201f2d70fe2218308d722028308d723208020d721d21ff83512baf2e094d31fd31fd31fed44d0d200d31f20d31fd3ffd70a0021db3cf2d0870af90140ccf9109a28945f0adb31e1f2c087df02b35007b0f2d0845125baf2e0855036ba1f2001d820abf78100ecbe8e1020ab0784efb084efba01807fb0c07fb0e08306b120843fb0208306bd218230b13802886d53fc85bdb00182304ec7fd7792ac03fabdb0923070e0208306ba2182e900000000000000000000000000000000000000000000000000000000000080bab121210156f2e086f823bbf2d08821841fbaf2d0852292f800de01a47fc8ca00cb1f01cf16c9ed542092f80fde70db3c22009282f026e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85bab10182f0c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fabab103b4eda2edfb02f404216e9132e30e01d20001c000925f03e020d70b07c0058ea6016eb312b1f2d71378d721d33ffa40d1ed44d0810141d721f4043120d74a91d4926d01e2d159e031ebd72c08142091709601d72c081c12e25210b123242500de521321d73930709421c700b38e4f01d72820761e436c20d749c008f2e09320d74ac002f2e093228e2c20d71d06c712c200f2d08920d70b077cb08e1820d74dd7393020d749c10292307095d70b01c003e2f2d093deded74cd7393001a4e86c128407bbf2e093d74ac000f2e093ed5501e202206e9530705470008e14d0d301d33fd33fd3ffd123c20024c104b0f2e70ee25b01c201f2d70f66baf2e70b20843fbaf2d7127101a4700320d74981010bba21d74ac000b0f2e71120d70b02c004f2e711fa44f828fa445033ba5213bd12b0f2e711413003c8cb0112cb3fcb3fcbffc9702601908e3930d72c08248e2d21f2e092d200ed44d0d2005113baf2d08f54503091319c01810140d721d70a00f2e08ee2c8ca0058cf16c9ed5493f2c08de2e30d20d74a935bdb31e1d74cd0270074ed44d0d200d31f810120d718f40430049a21841fbaf2d71201a401de24d0d70b01c201966c22706d4133de02c8ca00cb1f01cf16f400ccc9ed54009801fa4001fa44f828fa443058baf2e091ed44d0810141d718f404059d7fc8ca0040338307f453f2e08b8e14128307f45bf2e08c21d70a00216e01b3b0f2d090e2c858cf16f40058cf16c9ed542b7a0c8d"
}
