import BigInt
@testable import KeeperCore
import TonSwift
import XCTest

final class TOSV1DeeplinkPolicyTests: XCTestCase {
    func testAllowsOnlyNativeTOSSendReceiveAndBackup() throws {
        let nativeTransfer = Deeplink.transfer(.sendTransfer(.init(
            recipient: "0:test",
            amount: BigUInt(1),
            comment: nil,
            jettonAddress: nil,
            expirationTimestamp: nil,
            successReturn: nil
        )))

        XCTAssertTrue(TOSV1DeeplinkPolicy.allows(nativeTransfer))
        XCTAssertTrue(TOSV1DeeplinkPolicy.allows(.receive))
        XCTAssertTrue(TOSV1DeeplinkPolicy.allows(.backup))
    }

    func testRejectsJettonAndRawTransfers() throws {
        let jetton = try Address.parse("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c")
        XCTAssertFalse(TOSV1DeeplinkPolicy.allows(.transfer(.sendTransfer(.init(
            recipient: "0:test",
            amount: nil,
            comment: nil,
            jettonAddress: jetton,
            expirationTimestamp: nil,
            successReturn: nil
        )))))
        XCTAssertFalse(TOSV1DeeplinkPolicy.allows(.transfer(.signRawTransfer(.init(
            recipient: "0:test",
            amount: nil,
            jettonAddress: nil,
            bin: nil,
            stateInit: nil,
            expirationTimestamp: nil
        )))))
    }

    func testRejectsEveryInheritedTopLevelRoute() throws {
        let pool = try Address.parse("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c")
        let rejected: [Deeplink] = [
            .buyTon, .staking, .pool(pool), .exchange(provider: nil),
            .swap(.init(fromToken: nil, toToken: nil)), .action(eventId: "event"),
            .publish(sign: Data()), .browser, .battery(.init(promocode: nil, masterJettonAddress: nil)),
            .story(storyId: "story"),
        ]
        for deeplink in rejected {
            XCTAssertFalse(TOSV1DeeplinkPolicy.allows(deeplink), "Unexpectedly allowed: \(deeplink)")
        }
    }

    func testExternalBinaryPayloadCannotEnterNativeSendRoute() throws {
        try assertExternalCellRejected(parameter: "bin")
    }

    func testExternalStateInitCannotEnterNativeSendRoute() throws {
        try assertExternalCellRejected(parameter: "init")
    }

    private func assertExternalCellRejected(parameter: String) throws {
        let cell = try Builder().store(uint: 0x12345678, bits: 32).endCell().toBoc().base64EncodedString()
        var components = try XCTUnwrap(URLComponents(string: "tos://transfer/EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c"))
        components.queryItems = [URLQueryItem(name: "amount", value: "1"), URLQueryItem(name: parameter, value: cell)]
        let parsed = try DeeplinkParser().parse(string: XCTUnwrap(components.string))
        guard case .transfer(.signRawTransfer) = parsed else {
            return XCTFail("External cells must be classified as a raw transfer")
        }
        XCTAssertFalse(TOSV1DeeplinkPolicy.allows(parsed))
    }
}
