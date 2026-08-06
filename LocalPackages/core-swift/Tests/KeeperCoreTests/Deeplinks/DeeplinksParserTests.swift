import BigInt
@testable import KeeperCore
import TonSwift
import XCTest

final class DeeplinksParserTests: XCTestCase {
    let parser = DeeplinkParser()

    func testTransferTosWalletDeeplinkParsing() throws {
        let address = "EQD2NmD_lH5f5u1Kj3KfGyTvhZSX0Eg6qp2a5IQUKXxOG21n"
        let text = "just comment"
        let amount = "10000"

        let string = "tos://transfer/\(address)?text=\(text)&amount=\(amount)"
        let transferData = Deeplink.TransferData(
            recipient: address,
            amount: BigUInt(amount),
            comment: text,
            jettonAddress: nil,
            expirationTimestamp: nil,
            successReturn: nil
        )
        let result = Deeplink.transfer(.sendTransfer(transferData))
        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testTransferTonDeeplinkParsing() throws {
        let address = "EQD2NmD_lH5f5u1Kj3KfGyTvhZSX0Eg6qp2a5IQUKXxOG21n"
        let text = "just comment"
        let amount = "10000"

        let string = "ton://transfer/\(address)?text=\(text)&amount=\(amount)"
        let transferData = Deeplink.TransferData(
            recipient: address,
            amount: BigUInt(amount),
            comment: text,
            jettonAddress: nil,
            expirationTimestamp: nil,
            successReturn: nil
        )
        let result = Deeplink.transfer(.sendTransfer(transferData))
        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testTransferUniversalLinkParsing() throws {
        let address = "EQD2NmD_lH5f5u1Kj3KfGyTvhZSX0Eg6qp2a5IQUKXxOG21n"
        let text = "just comment"
        let amount = "10000"

        let string = "https://app.tos.network/transfer/\(address)?text=\(text)&amount=\(amount)"
        let transferData = Deeplink.TransferData(
            recipient: address,
            amount: BigUInt(amount),
            comment: text,
            jettonAddress: nil,
            expirationTimestamp: nil,
            successReturn: nil
        )
        let result = Deeplink.transfer(.sendTransfer(transferData))

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testStakingTonDeeplinkParsing() throws {
        let string = "ton://staking"
        let result = Deeplink.staking

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testStakingTosWalletDeeplinkParsing() throws {
        let string = "tos://staking"
        let result = Deeplink.staking

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testStakingTosWalletUniversalLinkParsing() throws {
        let string = "https://app.tos.network/staking"
        let result = Deeplink.staking

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testBuyTosWalletDeeplinkParsing() throws {
        let string = "tos://buy-ton"
        let result = Deeplink.buyTon

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testBuyTonTonDeeplinkParsing() throws {
        let string = "ton://buy-ton"
        let result = Deeplink.buyTon

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testBuyTosWalletUniversaLinkParsing() throws {
        let string = "https://app.tos.network/buy-ton"
        let result = Deeplink.buyTon

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testExchangeTonDeeplinkParsing() throws {
        let provider = "neocrypto"
        let string = "ton://exchange/neocrypto"
        let result = Deeplink.exchange(provider: provider)

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testExchangeTosWalletDeeplinkParsing() throws {
        let provider = "neocrypto"
        let string = "tos://exchange/neocrypto"
        let result = Deeplink.exchange(provider: provider)

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testExchangeTosWalletUniversalLinkParsing() throws {
        let provider = "neocrypto"
        let string = "https://app.tos.network/exchange/neocrypto"
        let result = Deeplink.exchange(provider: provider)

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testSwapTonDeeplinkParsing() throws {
        let string = "ton://swap?ft=TON&tt=FNZ"
        let swapData = Deeplink.SwapData(
            fromToken: "TON",
            toToken: "FNZ"
        )
        let result = Deeplink.swap(swapData)

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testSwapTosWalletDeeplinkParsing() throws {
        let string = "tos://swap?ft=TON&tt=FNZ"
        let swapData = Deeplink.SwapData(
            fromToken: "TON",
            toToken: "FNZ"
        )
        let result = Deeplink.swap(swapData)

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testSwapTosWalletUniversalLinkParsing() throws {
        let string = "https://app.tos.network/swap?ft=TON&tt=FNZ"
        let swapData = Deeplink.SwapData(
            fromToken: "TON",
            toToken: "FNZ"
        )
        let result = Deeplink.swap(swapData)

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testActionTonDeeplinkParsing() throws {
        let string = "ton://action/f0389f350dd7b6bba35ce0dd12d4e2cf557c2613bca2426d2e0c3055ac105994"
        let result = Deeplink.action(eventId: "f0389f350dd7b6bba35ce0dd12d4e2cf557c2613bca2426d2e0c3055ac105994")

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testActionTosWalletDeeplinkParsing() throws {
        let string = "tos://action/f0389f350dd7b6bba35ce0dd12d4e2cf557c2613bca2426d2e0c3055ac105994"
        let result = Deeplink.action(eventId: "f0389f350dd7b6bba35ce0dd12d4e2cf557c2613bca2426d2e0c3055ac105994")

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testActionTosWalletUniversalLinkParsing() throws {
        let string = "https://app.tos.network/action/f0389f350dd7b6bba35ce0dd12d4e2cf557c2613bca2426d2e0c3055ac105994"
        let result = Deeplink.action(eventId: "f0389f350dd7b6bba35ce0dd12d4e2cf557c2613bca2426d2e0c3055ac105994")

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testPoolTonDeeplinkParsing() throws {
        let string = "ton://pool/0:a45b17f28409229b78360e3290420f13e4fe20f90d7e2bf8c4ac6703259e22fa"
        let result = try Deeplink.pool(Address.parse("0:a45b17f28409229b78360e3290420f13e4fe20f90d7e2bf8c4ac6703259e22fa"))

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testPoolTosWalletDeeplinkParsing() throws {
        let string = "tos://pool/0:a45b17f28409229b78360e3290420f13e4fe20f90d7e2bf8c4ac6703259e22fa"
        let result = try Deeplink.pool(Address.parse("0:a45b17f28409229b78360e3290420f13e4fe20f90d7e2bf8c4ac6703259e22fa"))

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testPoolTosWalletUnversalLinkParsing() throws {
        let string = "https://app.tos.network/pool/0:a45b17f28409229b78360e3290420f13e4fe20f90d7e2bf8c4ac6703259e22fa"
        let result = try Deeplink.pool(Address.parse("0:a45b17f28409229b78360e3290420f13e4fe20f90d7e2bf8c4ac6703259e22fa"))

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testPublishTonDeeplinkParsing() throws {
        let string = "ton://publish?sign=9dfab96f693363f48a641c628ae74168d37f7da1745bfd3cbf1b6013cce1477c03ae59e87c8ebe0146c1d755b797020ac29ff6a1797e7ae7d4b61df89c34540f"
        let data: Data = Data(hex: "9dfab96f693363f48a641c628ae74168d37f7da1745bfd3cbf1b6013cce1477c03ae59e87c8ebe0146c1d755b797020ac29ff6a1797e7ae7d4b61df89c34540f")
        let result = Deeplink.publish(sign: data)

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testPublishTosWalletDeeplinkParsing() throws {
        let string = "tos://publish?sign=9dfab96f693363f48a641c628ae74168d37f7da1745bfd3cbf1b6013cce1477c03ae59e87c8ebe0146c1d755b797020ac29ff6a1797e7ae7d4b61df89c34540f"
        let data: Data = Data(hex: "9dfab96f693363f48a641c628ae74168d37f7da1745bfd3cbf1b6013cce1477c03ae59e87c8ebe0146c1d755b797020ac29ff6a1797e7ae7d4b61df89c34540f")
        let result = Deeplink.publish(sign: data)

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testPublishTosWalletUniversalLinkParsing() throws {
        let string = "https://app.tos.network/publish?sign=9dfab96f693363f48a641c628ae74168d37f7da1745bfd3cbf1b6013cce1477c03ae59e87c8ebe0146c1d755b797020ac29ff6a1797e7ae7d4b61df89c34540f"
        let data: Data = Data(hex: "9dfab96f693363f48a641c628ae74168d37f7da1745bfd3cbf1b6013cce1477c03ae59e87c8ebe0146c1d755b797020ac29ff6a1797e7ae7d4b61df89c34540f")
        let result = Deeplink.publish(sign: data)

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testSignerLinkTonDeeplinkParsing() throws {
        let pk = "db642e022c80911fe61f19eb4f22d7fb95c1ea0b589c0f74ecf0cbf6db746c13"
        let name = "MyKey"
        let publicKey = TonSwift.PublicKey(data: Data(hex: pk))
        let string = "ton://signer/link?pk=\(pk)&name=\(name)"
        let result = Deeplink.externalSign(
            ExternalSignDeeplink.link(
                publicKey: publicKey,
                name: name
            )
        )

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testSignerLinkTosWalletDeeplinkParsing() throws {
        let pk = "db642e022c80911fe61f19eb4f22d7fb95c1ea0b589c0f74ecf0cbf6db746c13"
        let name = "MyKey"
        let publicKey = TonSwift.PublicKey(data: Data(hex: pk))
        let string = "tos://signer/link?pk=\(pk)&name=\(name)"
        let result = Deeplink.externalSign(
            ExternalSignDeeplink.link(
                publicKey: publicKey,
                name: name
            )
        )

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testSignerLinkTosWalletUniversalLinkParsing() throws {
        let pk = "db642e022c80911fe61f19eb4f22d7fb95c1ea0b589c0f74ecf0cbf6db746c13"
        let name = "MyKey"
        let publicKey = TonSwift.PublicKey(data: Data(hex: pk))
        let string = "https://app.tos.network/signer/link?pk=\(pk)&name=\(name)"
        let result = Deeplink.externalSign(
            ExternalSignDeeplink.link(
                publicKey: publicKey,
                name: name
            )
        )

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testReceiveTosWalletDeeplinkParsing() throws {
        let string = "tos://receive"
        let result = Deeplink.receive

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testReceiveTonDeeplinkParsing() throws {
        let string = "ton://receive"
        let result = Deeplink.receive

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testBackupTosWalletDeeplinkParsing() throws {
        let string = "tos://backup"
        let result = Deeplink.backup

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }

    func testBackupTonDeeplinkParsing() throws {
        let string = "ton://backup"
        let result = Deeplink.backup

        let parsedDeeplink = try parser.parse(string: string)

        XCTAssertEqual(parsedDeeplink, result)
    }
}
