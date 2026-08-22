import BigInt
@testable import KeeperCore
import TonSwift
import XCTest

final class TOSTokenTransferEncodingTests: XCTestCase {
    private let recipient = try! Address.parse("0:\(String(repeating: "11", count: 32))")
    private let response = try! Address.parse("0:\(String(repeating: "22", count: 32))")

    func testJettonTransferMatchesTEP74WireLayout() throws {
        let value = JettonTransferData(
            queryId: 7,
            amount: 123_456_789,
            toAddress: recipient,
            responseAddress: response,
            forwardAmount: 1,
            forwardPayload: nil
        )
        let cell = try Builder().store(value).endCell()
        let wire = try cell.beginParse()
        XCTAssertEqual(try wire.loadUint(bits: 32), 0x0f8a7ea5)
        XCTAssertEqual(try wire.loadUint(bits: 64), 7)

        let decoded: JettonTransferData = try cell.beginParse().loadType()
        XCTAssertEqual(decoded.amount, BigUInt(123_456_789))
        XCTAssertEqual(decoded.toAddress, recipient)
        XCTAssertEqual(decoded.responseAddress, response)
        XCTAssertEqual(decoded.forwardAmount, 1)
        XCTAssertNil(decoded.customPayload)
    }

    func testNFTTransferMatchesTEP62WireLayout() throws {
        let message = try NFTTransferMessage.internalMessage(
            nftAddress: try Address.parse("0:\(String(repeating: "33", count: 32))"),
            nftTransferAmount: 100_000_000,
            bounce: true,
            to: recipient,
            responseAddress: response,
            forwardPayload: nil
        )
        let cell = message.body
        let wire = try cell.beginParse()
        XCTAssertEqual(try wire.loadUint(bits: 32), 0x5fcc3d14)

        let decoded: NFTTransferData = try cell.beginParse().loadType()
        XCTAssertEqual(decoded.newOwnerAddress, recipient)
        XCTAssertEqual(decoded.responseAddress, response)
        XCTAssertEqual(decoded.forwardAmount, 1)
    }
}
