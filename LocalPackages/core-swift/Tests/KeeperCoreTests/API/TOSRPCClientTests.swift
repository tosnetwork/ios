@testable import KeeperCore
import XCTest
import TonSwift

final class TOSRPCClientTests: XCTestCase {
    override func tearDown() {
        RPCURLProtocol.handler = nil
        TOSRPCConnectivity.setUnavailable(false)
        super.tearDown()
    }

    func testCallPostsJSONRPCToNodeEndpoint() async throws {
        RPCURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://node.test/jsonRPC")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body: Data
            if let httpBody = request.httpBody {
                body = httpBody
            } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = stream.read(&bytes, maxLength: bytes.count)
                body = Data(bytes.prefix(count))
            }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["method"] as? String, "getAddressInformation")
            XCTAssertEqual((json["params"] as? [String: String])?["address"], "0:test")
            return (200, #"{"ok":true,"result":{"balance":"42"}}"#)
        }

        let result = try await makeClient().call(
            method: "getAddressInformation",
            params: ["address": "0:test"]
        )

        XCTAssertEqual(result["balance"] as? String, "42")
    }

    func testCallSurfacesNodeError() async throws {
        TOSRPCConnectivity.setUnavailable(true)
        RPCURLProtocol.handler = { _ in
            (422, #"{"ok":false,"code":-32602,"error":"invalid address"}"#)
        }

        do {
            _ = try await makeClient().call(method: "getAddressInformation")
            XCTFail("Expected the node error")
        } catch let TOSRPCClient.Error.server(code, message) {
            XCTAssertEqual(code, -32602)
            XCTAssertEqual(message, "invalid address")
            XCTAssertFalse(
                TOSRPCConnectivity.isUnavailable,
                "A valid JSON-RPC error must prove the node is reachable"
            )
        }
    }

    func testCallRejectsMalformedResult() async throws {
        RPCURLProtocol.handler = { _ in (200, #"{"ok":true,"result":null}"#) }

        do {
            _ = try await makeClient().call(method: "getMasterchainInfo")
            XCTFail("Expected an invalid response error")
        } catch TOSRPCClient.Error.invalidResponse {
            // Expected.
        }
    }

    func testCallRejectsMalformedJSON() async throws {
        RPCURLProtocol.handler = { _ in (200, #"{"ok":true,"result": "#) }

        do {
            _ = try await makeClient().call(method: "getMasterchainInfo")
            XCTFail("Expected an invalid response error")
        } catch TOSRPCClient.Error.invalidResponse {
            // Expected.
        }
    }

    func testCallSurfacesTimeout() async throws {
        RPCURLProtocol.handler = { _ in throw URLError(.timedOut) }

        do {
            _ = try await makeClient().call(method: "getMasterchainInfo")
            XCTFail("Expected a timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
    }

    func testCallSurfacesUnavailableNode() async throws {
        var attempts = 0
        RPCURLProtocol.handler = { _ in
            attempts += 1
            throw URLError(.cannotConnectToHost)
        }

        do {
            _ = try await makeClient().call(method: "getMasterchainInfo")
            XCTFail("Expected an unavailable-node error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
            XCTAssertEqual(attempts, 2)
            XCTAssertTrue(TOSRPCConnectivity.isUnavailable)
        }
    }

    func testReadCallReconnectsAfterOneTransientFailure() async throws {
        var attempts = 0
        RPCURLProtocol.handler = { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.networkConnectionLost) }
            return (200, #"{"ok":true,"result":{"balance":"42"}}"#)
        }

        let result = try await makeClient().call(method: "getAddressInformation")

        XCTAssertEqual(result["balance"] as? String, "42")
        XCTAssertEqual(attempts, 2)
    }

    func testBroadcastIsNeverRetriedAfterAmbiguousNetworkFailure() async throws {
        var attempts = 0
        RPCURLProtocol.handler = { _ in
            attempts += 1
            throw URLError(.networkConnectionLost)
        }

        do {
            _ = try await makeClient().call(method: "sendBocReturnHash", params: ["boc": "fixture"])
            XCTFail("Expected the ambiguous broadcast failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
            XCTAssertEqual(attempts, 1)
        }
    }

    func testTLSAndCertificateFailuresAreReturnedWithoutRetry() async throws {
        for code in [URLError.secureConnectionFailed, .serverCertificateUntrusted, .clientCertificateRejected] {
            var attempts = 0
            RPCURLProtocol.handler = { _ in
                attempts += 1
                throw URLError(code)
            }

            do {
                _ = try await makeClient().call(method: "getMasterchainInfo")
                XCTFail("Expected TLS failure \(code)")
            } catch let error as URLError {
                XCTAssertEqual(error.code, code)
                XCTAssertEqual(attempts, 1)
            }
        }
    }

    func testWalletBroadcastKeepsVerifiedEndpointWhenSettingChangesDuringAwait() async throws {
        var endpoint = "http://node.test"
        var methods = [String]()
        RPCURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "node.test")
            let body = try Self.requestBody(request)
            let method = try XCTUnwrap(body["method"] as? String)
            methods.append(method)
            if method == "getConfigParam" {
                // An endpoint edit while the identity request is in flight must
                // not send this operation's BOC to the newly selected node.
                endpoint = "http://unverified.test"
                return (200, try Self.configurationResponse(requestBody: body))
            }
            return (200, #"{"ok":true,"result":{"hash":"accepted"}}"#)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RPCURLProtocol.self]
        let client = TOSRPCClient(basePath: { endpoint }, urlSession: URLSession(configuration: configuration))
        _ = try await client.callForWallet(method: "sendBocReturnHash", params: ["boc": "fixture"], wallet: makeTOSWallet(globalId: 3))
        XCTAssertEqual(methods, ["getConfigParam", "getConfigParam", "sendBocReturnHash"])
        XCTAssertEqual(endpoint, "http://unverified.test")
    }

    func testWrongNodeIdentityRejectsBroadcastBeforeSubmission() async throws {
        var methods = [String]()
        RPCURLProtocol.handler = { request in
            let body = try Self.requestBody(request)
            methods.append(try XCTUnwrap(body["method"] as? String))
            return (200, try Self.configurationResponse(requestBody: body))
        }
        do {
            _ = try await makeClient().callForWallet(method: "sendBocReturnHash", params: ["boc": "fixture"], wallet: makeTOSWallet(globalId: -239))
            XCTFail("A wrong network must never receive the signed BOC")
        } catch let TOSNetworkIdentityError.wrongNetwork(expected, actual) {
            XCTAssertEqual(expected, -239)
            XCTAssertEqual(actual, 3)
            XCTAssertEqual(methods, ["getConfigParam"])
        }
    }

    func testFirstDeploymentEstimateSuppliesInitOnVerifiedEndpoint() async throws {
        var endpoint = "http://node.test"
        var methods = [String]()
        let wallet = makeTOSWallet(globalId: 3)
        RPCURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "node.test")
            let json = try Self.requestBody(request)
            let method = try XCTUnwrap(json["method"] as? String)
            methods.append(method)
            switch method {
            case "getConfigParam":
                return (200, try Self.configurationResponse(requestBody: json))
            case "getWalletInformation":
                endpoint = "http://unverified.test"
                return (200, #"{"ok":true,"result":{"account_state":"uninitialized","wallet":false}}"#)
            default:
                XCTAssertEqual(method, "estimateFee")
                let params = try XCTUnwrap(json["params"] as? [String: Any])
                XCTAssertEqual(params["body"] as? String, "signed-wallet-body")
                XCTAssertEqual(params["ignore_chksig"] as? Bool, true)
                let codeData = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(params["init_code"] as? String)))
                let code = try XCTUnwrap(Cell.fromBoc(src: codeData).first)
                XCTAssertEqual(code.hash(), try XCTUnwrap(Data(hex: "086a86aa9913c0ec52277adbb7e4b5695964dbb8c817ad0c305cdd345bbfac69")))
                let data = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(params["init_data"] as? String)))
                let slice = try XCTUnwrap(Cell.fromBoc(src: data).first).beginParse()
                XCTAssertTrue(try slice.loadBoolean())
                XCTAssertEqual(try slice.loadUint(bits: 32), 0)
                return (200, #"{"ok":true,"result":{"source_fees":{"in_fwd_fee":"1","storage_fee":"2","gas_fee":"3","fwd_fee":"4"}}}"#)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RPCURLProtocol.self]
        let client = TOSRPCClient(basePath: { endpoint }, urlSession: URLSession(configuration: configuration))
        let fee = try await client.estimateWalletFee(body: "signed-wallet-body", wallet: wallet)
        XCTAssertEqual(fee, 10)
        XCTAssertEqual(methods, ["getConfigParam", "getConfigParam", "getWalletInformation", "estimateFee"])
    }

    func testActiveWalletEstimateUsesChainStateWithoutDeploymentInit() async throws {
        RPCURLProtocol.handler = { request in
            let json = try Self.requestBody(request)
            switch json["method"] as? String {
            case "getConfigParam":
                return (200, try Self.configurationResponse(requestBody: json))
            case "getWalletInformation":
                return (200, #"{"ok":true,"result":{"account_state":"active","wallet":true,"seqno":7}}"#)
            default:
                let params = try XCTUnwrap(json["params"] as? [String: Any])
                XCTAssertNil(params["init_code"])
                XCTAssertNil(params["init_data"])
                return (200, #"{"ok":true,"result":{"source_fees":{"in_fwd_fee":1,"storage_fee":2,"gas_fee":3,"fwd_fee":4}}}"#)
            }
        }
        let fee = try await makeClient().estimateWalletFee(body: "body", wallet: makeTOSWallet(globalId: 3))
        XCTAssertEqual(fee, 10)
    }

    func testOldOrMissingVMCapabilityRejectsWalletDiscoveryAndBroadcast() async throws {
        for version in [UInt32(0), 5] {
            var methods = [String]()
            RPCURLProtocol.handler = { request in
                let body = try Self.requestBody(request)
                methods.append(try XCTUnwrap(body["method"] as? String))
                return (200, try Self.configurationResponse(requestBody: body, vmVersion: version))
            }
            do {
                _ = try await makeClient().getVerifiedNetworkGlobalId()
                XCTFail("Unsupported nodes must not create a native wallet")
            } catch let TOSNetworkIdentityError.unsupportedVMVersion(actual) {
                XCTAssertEqual(actual, version)
            }
            methods.removeAll()
            do {
                _ = try await makeClient().callForWallet(method: "sendBocReturnHash", params: ["boc": "fixture"], wallet: makeTOSWallet(globalId: 3))
                XCTFail("Unsupported nodes must not receive a broadcast")
            } catch let TOSNetworkIdentityError.unsupportedVMVersion(actual) {
                XCTAssertEqual(actual, version)
                XCTAssertEqual(methods, ["getConfigParam", "getConfigParam"])
            }
        }
        RPCURLProtocol.handler = { request in
            let body = try Self.requestBody(request)
            if (body["params"] as? [String: Int])?["param"] == 19 {
                return (200, try Self.configurationResponse(requestBody: body))
            }
            return (200, #"{"ok":true,"result":{}}"#)
        }
        do {
            _ = try await makeClient().getVerifiedNetworkGlobalId()
            XCTFail("Missing capabilities must fail closed")
        } catch TOSNetworkIdentityError.invalidConfiguration {
            // Expected.
        }
    }

    private static func configurationResponse(requestBody: [String: Any], vmVersion: UInt32 = 18) throws -> String {
        let parameter = try XCTUnwrap((requestBody["params"] as? [String: Int])?["param"])
        let cell: Cell
        if parameter == 19 {
            cell = try Builder().store(int: 3, bits: 32).endCell()
        } else {
            XCTAssertEqual(parameter, 8)
            cell = try Builder().store(uint: 0xc4, bits: 8).store(uint: vmVersion, bits: 32).store(uint: 0, bits: 64).endCell()
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "result": ["config": ["bytes": try cell.toBoc().base64EncodedString()]]])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func makeTOSWallet(globalId: Int32) -> Wallet {
        Wallet(id: "fixture", identity: WalletIdentity(network: .mainnet, kind: .Regular(PublicKey(data: Data(repeating: 0, count: 32)), .tosV5R1), networkGlobalId: globalId), metaData: WalletMetaData(label: "Fixture", tintColor: .defaultColor, icon: .icon(.wallet)), setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody { return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count == 0 { break }
            guard count > 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            data.append(contentsOf: bytes.prefix(count))
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeClient() -> TOSRPCClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RPCURLProtocol.self]
        return TOSRPCClient(basePath: { "http://node.test/" }, urlSession: URLSession(configuration: configuration))
    }
}

private final class RPCURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, body) = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
