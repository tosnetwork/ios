import BigInt
@testable import KeeperCore
import TonSwift
import XCTest

final class TOSWalletV5R1Tests: XCTestCase {
    private let publicKey = Data(hex: "5754865e86d0ade1199301bbb0319a25ed6b129c4b0a57f28f62449b3df9c522")!

    func testMatchesIndependentTOSSDKAddressAndSigningVectors() throws {
        let data = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "tos-v5-reference-vectors", withExtension: "json")))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let vectors = try XCTUnwrap(fixture["vectors"] as? [[String: Any]])
        for vector in vectors {
            let publicKey = try XCTUnwrap(Data(hex: XCTUnwrap(vector["public_key"] as? String)))
            let wallet = try TOSWalletV5R1(publicKey: publicKey, networkGlobalId: Int32(XCTUnwrap(vector["network_global_id"] as? Int)))
            XCTAssertEqual(try wallet.address().toRaw(), vector["address"] as? String)
            XCTAssertEqual(wallet.code.hash(), try XCTUnwrap(Data(hex: XCTUnwrap(vector["code_hash"] as? String))))
            let transfer = try wallet.createTransfer(args: WalletTransferData(
                seqno: UInt64(XCTUnwrap(vector["seqno"] as? Int)),
                messages: [MessageRelaxed.internal(to: Address.parse(XCTUnwrap(vector["destination"] as? String)), value: BigUInt(XCTUnwrap(vector["value"] as? UInt64)), bounce: true)],
                sendMode: .walletDefault(), timeout: UInt64(XCTUnwrap(vector["valid_until"] as? Int))
            ))
            XCTAssertEqual(try transfer.signingMessage.endCell().hash(), try XCTUnwrap(Data(hex: XCTUnwrap(vector["signing_message_hash"] as? String))))
        }
    }

    func testSignatureCoversSeparateSignedNetworkIdentityAndPlainSubwallet() throws {
        let first = try makeTransfer(network: 3)
        let second = try makeTransfer(network: -239)
        XCTAssertNotEqual(try first.signingMessage.endCell().hash(), try second.signingMessage.endCell().hash())
        let wire = try first.signingMessage.endCell().beginParse()
        XCTAssertEqual(try wire.loadUint(bits: 32), 0x7369676e)
        XCTAssertEqual(try wire.loadInt(bits: 32), 3)
        XCTAssertEqual(try wire.loadUint(bits: 32), 0)
        XCTAssertEqual(try wire.loadUint(bits: 32), 2_000_000_000)
        XCTAssertEqual(try wire.loadUint(bits: 32), 7)
        XCTAssertEqual(try wire.loadBit(), 1)
        XCTAssertEqual(try wire.loadBit(), 0)
    }

    func testLegacyTONContractRemainsDistinctFromTOSContract() throws {
        let legacy = WalletV5R1(publicKey: publicKey, walletId: WalletId(networkGlobalId: -239))
        let current = try TOSWalletV5R1(publicKey: publicKey, networkGlobalId: 3)
        XCTAssertNotEqual(try legacy.address(), try current.address())
        XCTAssertEqual(WalletContractVersion.currentVersion, .tosV5R1)
        let identity = WalletIdentity(network: .mainnet, kind: .Regular(PublicKey(data: publicKey), .v5R1))
        let encoded = try JSONEncoder().encode(identity)
        XCTAssertEqual(try JSONDecoder().decode(WalletIdentity.self, from: encoded), identity)
    }

    func testTOSWalletIdentityPersistsNetworkAndLegacyEncodingStaysUnchanged() throws {
        let legacy = WalletIdentity(network: .mainnet, kind: .Regular(PublicKey(data: publicKey), .v5R1))
        let current = WalletIdentity(network: .mainnet, kind: .Regular(PublicKey(data: publicKey), .tosV5R1), networkGlobalId: -2147483648)
        let legacyBits = try Builder().store(legacy).bitstring()
        XCTAssertEqual(legacyBits.length, 16 + 5 + 256 + 4)
        let restored = try JSONDecoder().decode(WalletIdentity.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(restored, current)
        XCTAssertEqual(restored.networkGlobalId, Int32.min)
        XCTAssertThrowsError(try Builder().store(WalletIdentity(network: .mainnet, kind: .Regular(PublicKey(data: publicKey), .tosV5R1))))
    }

    func testRejectsOutOfRangeSequenceExpirationAndExcessActions() throws {
        let wallet = try TOSWalletV5R1(publicKey: publicKey, networkGlobalId: 3)
        let message = MessageRelaxed.internal(to: try Address.parse("0:" + String(repeating: "11", count: 32)), value: 1, bounce: true)
        XCTAssertThrowsError(try wallet.createTransfer(args: WalletTransferData(seqno: UInt64(UInt32.max) + 1, messages: [message], sendMode: .walletDefault(), timeout: 2_000_000_000)))
        XCTAssertThrowsError(try wallet.createTransfer(args: WalletTransferData(seqno: 0, messages: [message], sendMode: .walletDefault(), timeout: UInt64(UInt32.max) + 1)))
        XCTAssertThrowsError(try wallet.createTransfer(args: WalletTransferData(seqno: 1, messages: Array(repeating: message, count: 256), sendMode: .walletDefault(), timeout: 2_000_000_000)))
        XCTAssertThrowsError(try TOSWalletV5R1(publicKey: Data(repeating: 0, count: 31), networkGlobalId: 3))
    }

    func testInitialTransferRespectsExplicitExpiry() throws {
        let wallet = try TOSWalletV5R1(publicKey: publicKey, networkGlobalId: 3)
        let transfer = try wallet.createTransfer(args: WalletTransferData(seqno: 0, messages: [], sendMode: .walletDefault(), timeout: 2_000_000_000))
        let wire = try transfer.signingMessage.endCell().beginParse()
        _ = try wire.loadUint(bits: 32)
        _ = try wire.loadInt(bits: 32)
        _ = try wire.loadUint(bits: 32)
        XCTAssertEqual(try wire.loadUint(bits: 32), 2_000_000_000)
        XCTAssertEqual(try wire.loadUint(bits: 32), 0)
        XCTAssertEqual(try wire.loadBit(), 0)
    }

    private func makeTransfer(network: Int32) throws -> WalletTransfer {
        try TOSWalletV5R1(publicKey: publicKey, networkGlobalId: network).createTransfer(args: WalletTransferData(
            seqno: 7,
            messages: [MessageRelaxed.internal(to: Address.parse("0:" + String(repeating: "11", count: 32)), value: 123_456_789, bounce: true)],
            sendMode: .walletDefault(), timeout: 2_000_000_000
        ))
    }
}
