import XCTest
@testable import CoreComponents

final class TOSQuantumProofHTTPTransportTests: XCTestCase {
    private final class Fixture: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var mode = "valid"
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                if Self.mode == "stall" { return }
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        guard count >= 0 else { throw TOSPQError.invalidInput }
                        if count == 0 { break }; body.append(contentsOf: buffer.prefix(count))
                    }
                }
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(object["method"] as? String, "getProofQuery")
                let id = try XCTUnwrap(object["id"] as? String)
                var reply = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": Self.mode == "wrongID" ? "other" : id,
                    "result": ["reply": "AQIDBA=="]])
                if Self.mode == "trailing" { reply.append(Data("{}".utf8)) }
                if Self.mode == "large" { reply = Data(repeating: 32, count: 8192) }
                let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: Self.mode == "redirect" ? 302 : 200,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() { }
    }
    func testReplyAndUntrustedEnvelopeFailures() throws {
        for mode in ["valid", "wrongID", "trailing", "large", "redirect", "decodedLimit", "cancelled", "stall"] {
            Fixture.mode = mode
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [Fixture.self]
            let transport = try TOSQuantumProofHTTPTransport(endpoint: URL(string: "https://proof.example/jsonRPC")!, configuration: config, timeout: 0.3)
            let done = expectation(description: mode)
            DispatchQueue.global().async {
                defer { done.fulfill() }
                do {
                    let bytes = try transport.query(Data([1, 2, 3, 4]), maximumBytes: mode == "decodedLimit" ? 2 : 16,
                                                    isCancelled: { mode == "cancelled" })
                    if mode == "valid" { XCTAssertEqual(bytes, Data([1, 2, 3, 4])) }
                    else { XCTFail("Untrusted proof response accepted: " + mode) }
                } catch { if mode == "valid" { XCTFail("Valid reply refused: \(error)") } }
            }
            wait(for: [done], timeout: 5)
        }
    }
}
