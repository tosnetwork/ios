import Foundation
@testable import KeeperCore
import TonSwift
import XCTest

final class TOSWalletBackgroundCursorRPCTests: XCTestCase {
    override func tearDown() {
        BackgroundCursorURLProtocol.handler = nil
        TOSRPCConnectivity.setUnavailable(false)
        super.tearDown()
    }

    func testCursorReadUsesOneEndpointForIdentityVMAndWalletInformation() async throws {
        var endpoint = "http://cursor-node.test"
        var methods = [String]()
        BackgroundCursorURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "cursor-node.test")
            let body = try Self.requestBody(request)
            let method = try XCTUnwrap(body["method"] as? String)
            methods.append(method)
            if method == "getConfigParam" {
                endpoint = "http://changed-node.test"
                return try Self.configurationResponse(body, vmVersion: 18)
            }
            XCTAssertEqual(method, "getWalletInformation")
            let params = try XCTUnwrap(body["params"] as? [String: Any])
            XCTAssertEqual(params["address"] as? String, try Self.fixtureWallet().address.toRaw())
            return ["last_transaction_id": ["lt": "42", "hash": Data(repeating: 1, count: 32).base64EncodedString()]]
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackgroundCursorURLProtocol.self]
        let client = TOSRPCClient(basePath: { endpoint }, urlSession: URLSession(configuration: configuration))
        let cursor = try await client.walletBackgroundUpdateCursor(wallet: Self.fixtureWallet())
        XCTAssertEqual(cursor.lt, 42)
        XCTAssertEqual(methods, ["getConfigParam", "getConfigParam", "getWalletInformation"])
        XCTAssertEqual(endpoint, "http://changed-node.test")
    }

    func testWrongIdentityAndUnsupportedVMDoNotProduceCursorReads() async throws {
        for (globalID, vmVersion, expectedRequests) in [(Int32(-239), UInt32(18), 1), (Int32(3), UInt32(5), 2)] {
            var methods = [String]()
            BackgroundCursorURLProtocol.handler = { request in
                let body = try Self.requestBody(request)
                let method = try XCTUnwrap(body["method"] as? String)
                methods.append(method)
                XCTAssertEqual(method, "getConfigParam")
                return try Self.configurationResponse(body, vmVersion: vmVersion)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BackgroundCursorURLProtocol.self]
            let client = TOSRPCClient(basePath: { "http://cursor-node.test" }, urlSession: URLSession(configuration: configuration))
            do {
                _ = try await client.walletBackgroundUpdateCursor(wallet: Self.fixtureWallet(globalID: globalID))
                XCTFail("An unverified node produced a background cursor")
            } catch is TOSNetworkIdentityError {
                XCTAssertEqual(methods, Array(repeating: "getConfigParam", count: expectedRequests))
            }
        }
    }

    private static func fixtureWallet(globalID: Int32 = 3) -> Wallet {
        Wallet(id: "background-rpc-fixture", identity: WalletIdentity(network: .mainnet, kind: .Regular(PublicKey(data: Data(repeating: 0, count: 32)), .tosV5R1), networkGlobalId: globalID), metaData: WalletMetaData(label: "Fixture", tintColor: .defaultColor, icon: .icon(.wallet)), setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
    }

    private static func configurationResponse(_ body: [String: Any], vmVersion: UInt32) throws -> [String: Any] {
        let parameter = try XCTUnwrap((body["params"] as? [String: Int])?["param"])
        let cell: Cell
        if parameter == 19 {
            cell = try Builder().store(int: 3, bits: 32).endCell()
        } else {
            XCTAssertEqual(parameter, 8)
            cell = try Builder().store(uint: 0xc4, bits: 8).store(uint: vmVersion, bits: 32).store(uint: 0, bits: 64).endCell()
        }
        return ["config": ["bytes": try cell.toBoc().base64EncodedString()]]
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        if let body = request.httpBody {
            return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 4096)
        var body = Data()
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count == 0 { break }
            guard count > 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            body.append(contentsOf: bytes.prefix(count))
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

private final class BackgroundCursorURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> [String: Any])?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let result = try XCTUnwrap(Self.handler)(request)
            let body = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
