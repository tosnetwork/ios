import XCTest
import Foundation
@testable import KeeperCore

final class TOSTokenMetadataTests: XCTestCase {
    private func decode(_ text: String) throws -> TOSTokenMetadata { try .decode(Data(text.utf8)) }

    func testPrecisionAndUnicodeFieldsRemainBounded() throws {
        XCTAssertEqual(try decode(#"{"name":"测试币","symbol":"CR","decimals":"6"}"#),
                       TOSTokenMetadata(name: "测试币", symbol: "CR", decimals: 6))
        XCTAssertEqual(try decode("{}").decimals, 9)
        XCTAssertEqual(try decode(#"{"decimals":0}"#).decimals, 0)
        XCTAssertEqual(try decode(#"{"decimals":"255"}"#).decimals, 255)
        for value in ["true", "null", "6.0", "1e1", "-1", "256", #""9x""#, #""1000""#] {
            XCTAssertThrowsError(try decode("{\"decimals\":\(value)}"), value)
        }
    }

    func testMalformedOversizedAndDeepJSONAreRejected() throws {
        for value in ["[]", "{}{}", #"{"name":7}"#,
                      "{\"symbol\":\"" + String(repeating: "x", count: 33) + "\"}",
                      "{\"name\":\"" + String(repeating: "测", count: 43) + "\"}",
                      "{\"ignored\":" + String(repeating: "[", count: 9) + "0" + String(repeating: "]", count: 9) + "}"] {
            XCTAssertThrowsError(try decode(value))
        }
        XCTAssertThrowsError(try TOSTokenMetadata.decode(Data([123, 34, 255, 34, 58, 48, 125])))
        XCTAssertThrowsError(try TOSTokenMetadata.decode(Data(repeating: 32, count: 65_537)))
    }

    func testHTTPSAndIPFSPointersDoNotAcceptCredentialsOrFragments() throws {
        XCTAssertEqual(try TOSTokenMetadata.url("https://example.test/token.json").absoluteString, "https://example.test/token.json")
        XCTAssertEqual(try TOSTokenMetadata.url("ipfs://bafyexample/token.json").absoluteString, "https://ipfs.io/ipfs/bafyexample/token.json")
        for uri in ["http://example.test/a", "file:///tmp/a", "javascript:alert(1)",
                    "https://user:secret@example.test/a", "https://example.test/a#fragment",
                    "https://example.test/" + String(repeating: "a", count: 2048)] {
            XCTAssertThrowsError(try TOSTokenMetadata.url(uri))
        }
    }

    private final class Fixture: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let mode = request.url!.lastPathComponent
            if mode == "stall" { return }
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.httpMethod, "GET")
            let headers = mode == "largeKnown" ? ["Content-Length": "65537"] : [:]
            let response = HTTPURLResponse(url: request.url!, statusCode: mode == "redirect" ? 302 : 200,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let bytes = mode == "largeUnknown" ? Data(repeating: 32, count: 65_537) : Data("{}".utf8)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() { }
    }

    func testIsolatedReadRejectsOversizeRedirectTimeoutAndCancellation() {
        for mode in ["valid", "largeKnown", "largeUnknown", "redirect", "stall", "cancelled"] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [Fixture.self]
            config.httpAdditionalHeaders = ["Authorization": "PRIVATE-FIXTURE", "X-API-Key": "PRIVATE-FIXTURE", "Cookie": "PRIVATE-FIXTURE"]
            let done = expectation(description: mode)
            DispatchQueue.global().async {
                defer { done.fulfill() }
                do {
                    let bytes = try TOSQuantumRPCTransport.readTokenMetadata(url: URL(string: "https://metadata.test/\(mode)")!,
                        configuration: config, timeout: mode == "stall" ? 0.3 : 3, isCancelled: { mode == "cancelled" })
                    if mode == "valid" { XCTAssertEqual(try TOSTokenMetadata.decode(bytes).decimals, 9) }
                    else { XCTFail("Unsafe metadata accepted: \(mode)") }
                } catch { if mode == "valid" { XCTFail("Valid metadata refused: \(error)") } }
            }
            wait(for: [done], timeout: 5)
        }
    }
}
