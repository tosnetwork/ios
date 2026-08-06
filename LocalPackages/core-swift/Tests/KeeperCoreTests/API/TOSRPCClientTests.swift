@testable import KeeperCore
import XCTest

final class TOSRPCClientTests: XCTestCase {
    override func tearDown() {
        RPCURLProtocol.handler = nil
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
        RPCURLProtocol.handler = { _ in
            (422, #"{"ok":false,"code":-32602,"error":"invalid address"}"#)
        }

        do {
            _ = try await makeClient().call(method: "getAddressInformation")
            XCTFail("Expected the node error")
        } catch let TOSRPCClient.Error.server(code, message) {
            XCTAssertEqual(code, -32602)
            XCTAssertEqual(message, "invalid address")
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
        RPCURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }

        do {
            _ = try await makeClient().call(method: "getMasterchainInfo")
            XCTFail("Expected an unavailable-node error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        }
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
