import XCTest
import Foundation
import CoreComponents
@testable import KeeperCore

final class TOSQuantumRPCTransportTests: XCTestCase {
    private final class Fixture: URLProtocol {
        nonisolated(unsafe) static var mode = "valid"
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                if Self.mode == "stall" { return }
                var raw = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        guard count >= 0 else { throw TOSPQError.invalidInput }
                        if count == 0 { break }; raw.append(contentsOf: buffer.prefix(count))
                    }
                }
                let request = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
                let id = try XCTUnwrap(request["id"] as? String)
                var reply = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": Self.mode == "wrongID" ? "wrong" : id,
                    "result": [["data": "PUBLIC"]]])
                if Self.mode == "trailing" { reply.append(Data("{}".utf8)) }
                if Self.mode == "large" { reply = Data(repeating: 32, count: 2048) }
                if Self.mode == "deep" {
                    reply = Data(("{\"jsonrpc\":\"2.0\",\"id\":\"" + id + "\",\"result\":" +
                        String(repeating: "[", count: 70) + "0" + String(repeating: "]", count: 70) + "}").utf8)
                }
                let response = try XCTUnwrap(HTTPURLResponse(url: self.request.url!, statusCode: Self.mode == "redirect" ? 302 : 200,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() { }
    }

    func testBoundedTransactionRelayRejectsMismatchedUnboundedAndCancelledReplies() throws {
        for mode in ["valid", "wrongID", "trailing", "large", "deep", "redirect", "cancelled", "stall", "unsupported"] {
            Fixture.mode = mode
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Fixture.self]
            let relay = try TOSQuantumRPCTransport(endpoint: URL(string: "https://relay.example/jsonRPC")!, configuration: config, timeout: 0.3)
            let done = expectation(description: mode)
            DispatchQueue.global().async {
                defer { done.fulfill() }
                do {
                    let result = try relay.call(method: mode == "unsupported" ? "getAddressInformation" : "getTransactions",
                        params: ["address": "0:" + String(repeating: "0", count: 64), "limit": 1], maximumBytes: 512,
                        isCancelled: { mode == "cancelled" })
                    if mode == "valid" { XCTAssertEqual((result as? [[String: String]])?.first?["data"], "PUBLIC") }
                    else { XCTFail("Untrusted relay mode accepted: " + mode) }
                } catch { if mode == "valid" { XCTFail("Valid relay refused: \(error)") } }
            }
            wait(for: [done], timeout: 5)
        }
    }
}
