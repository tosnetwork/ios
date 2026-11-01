@testable import KeeperCore
import Foundation
import TonSwift
import XCTest

final class TOSNativeWalletRPCTests: XCTestCase {
    override func tearDown() {
        NativeRPCURLProtocol.handler = nil
        TOSRPCConnectivity.setUnavailable(false)
        super.tearDown()
    }
    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tos-native-active-wallet", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func wallet() throws -> Wallet {
        let key = try XCTUnwrap(Data(hex: XCTUnwrap(fixture()["public_key"] as? String)))
        return Wallet(id: "native-test", identity: WalletIdentity(network: .mainnet,
            kind: .Regular(PublicKey(data: key), .tosV5R1), networkGlobalId: 3),
            metaData: WalletMetaData(label: "Public native fixture", tintColor: .defaultColor, icon: .icon(.wallet)),
            setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
    }
    private func snapshot() throws -> [String: Any] {
        ["state": "active", "code": try TOSLegacyWalletRPC.initialComponents(wallet: wallet()).code.toBoc().base64EncodedString(),
         "data": try XCTUnwrap(fixture()["data_boc"] as? String)]
    }
    private func data(seqno: UInt32 = 1, signatures: Bool = true, subwallet: UInt32 = 0,
                      key: Data? = nil, extra: Bool = false) throws -> Cell {
        let publicKey = try key ?? XCTUnwrap(Data(hex: XCTUnwrap(fixture()["public_key"] as? String)))
        let builder = try Builder().store(bit: signatures).store(uint: seqno, bits: 32)
            .store(uint: subwallet, bits: 32).store(data: publicKey).store(bit: false)
        if extra { try builder.store(bit: false) }
        return try builder.endCell()
    }
    private static func response(_ result: [String: Any]) throws -> (Int, String) {
        (200, try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: ["result": result]), encoding: .utf8)))
    }
    private func client() -> TOSRPCClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeRPCURLProtocol.self]
        return TOSRPCClient(basePath: { "http://native.test" }, urlSession: URLSession(configuration: configuration))
    }
    private static func request(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count == 0 { break }
                guard count > 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testRecordedNativeCounterSurvivesAnUnclassifiedNodeResponse() async throws {
        let fixture = try fixture(); let wallet = try wallet(); let snapshot = try snapshot()
        let address = try Address.parse(XCTUnwrap(fixture["address"] as? String))
        XCTAssertEqual(try wallet.address, address)
        XCTAssertEqual(try TOSLegacyWalletRPC.initialComponents(wallet: wallet).code.hash().map { String(format: "%02x", $0) }.joined(), fixture["code_hash"] as? String)
        var methods = [String]()
        NativeRPCURLProtocol.handler = { request in
            let method = try XCTUnwrap(Self.request(request)["method"] as? String)
            methods.append(method)
            return (200, try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: ["result": method == "getWalletInformation" ? XCTUnwrap(fixture["wallet_information"]) : snapshot]), encoding: .utf8)))
        }
        let information = try await client().walletInformation(address: address)
        XCTAssertEqual(try TOSWalletRPC.decodeSeqno(information), 1)
        XCTAssertEqual(methods, ["getWalletInformation", "getAddressInformation"])
    }

    func testTypedNativeClientVerifiesNetworkThenReadsItsBoundSnapshot() async throws {
        let snapshot = try snapshot(); var methods = [String]()
        NativeRPCURLProtocol.handler = { request in
            let body = try Self.request(request); let method = try XCTUnwrap(body["method"] as? String)
            methods.append(method)
            if method == "getConfigParam" {
                let parameter = try XCTUnwrap((body["params"] as? [String: Int])?["param"])
                let cell = parameter == 19 ? try Builder().store(int: 3, bits: 32).endCell() :
                    try Builder().store(uint: 0xc4, bits: 8).store(uint: 16, bits: 32).store(uint: 0, bits: 64).endCell()
                return try Self.response(["config": ["bytes": try cell.toBoc().base64EncodedString()]])
            }
            XCTAssertEqual(method, "getAddressInformation")
            return try Self.response(snapshot)
        }
        let info = try await client().walletInformation(wallet: wallet())
        XCTAssertEqual(try TOSWalletRPC.decodeSeqno(info), 1)
        XCTAssertEqual(methods, ["getConfigParam", "getConfigParam", "getAddressInformation"])
    }

    func testCodeMustMatchTheShippedNativeContract() throws {
        var wrong = try snapshot(); wrong["code"] = try Builder().endCell().toBoc().base64EncodedString()
        XCTAssertThrowsError(try TOSNativeWalletRPC.normalizeSnapshot(wrong, address: wallet().address, expectedWallet: wallet()))
    }

    func testStateKeyAndSubwalletMustReconstructTheOriginalAddress() throws {
        for value in [try data(key: Data(count: 32)), try data(subwallet: 1)] {
            var wrong = try snapshot(); wrong["data"] = try value.toBoc().base64EncodedString()
            XCTAssertThrowsError(try TOSNativeWalletRPC.normalizeSnapshot(wrong, address: wallet().address, expectedWallet: wallet()))
        }
    }

    func testDisabledSignaturesAndExtraDataCannotProduceACounter() throws {
        for value in [try data(signatures: false), try data(extra: true)] {
            var wrong = try snapshot(); wrong["data"] = try value.toBoc().base64EncodedString()
            XCTAssertThrowsError(try TOSNativeWalletRPC.normalizeSnapshot(wrong, address: wallet().address, expectedWallet: wallet()))
        }
        var maximum = try snapshot(); maximum["data"] = try data(seqno: UInt32.max).toBoc().base64EncodedString()
        XCTAssertEqual(try TOSWalletRPC.decodeSeqno(TOSNativeWalletRPC.normalizeSnapshot(maximum, address: wallet().address)), UInt32.max)
    }

    func testMalformedOrdinaryBocsAreRejectedBeforeSdkParsing() throws {
        let malformed = try TOSRPCBOCTestFixtures.malformedBase64()
        for field in ["code", "data"] {
            for text in malformed + ["", "not-base64"] {
                var wrong = try snapshot(); wrong[field] = text
                XCTAssertThrowsError(try TOSNativeWalletRPC.normalizeSnapshot(wrong, address: wallet().address))
            }
        }
    }

    func testOnlyStoredNativeIdentityAndEmptyUninitializedStateProduceZero() throws {
        let empty: [String: Any] = ["state": "uninitialized", "code": "", "data": ""]
        XCTAssertEqual(try TOSWalletRPC.decodeSeqno(TOSNativeWalletRPC.normalizeSnapshot(empty, address: wallet().address, expectedWallet: wallet())), 0)
        XCTAssertThrowsError(try TOSNativeWalletRPC.normalizeSnapshot(empty, address: wallet().address))
        var nonempty = empty; nonempty["data"] = try XCTUnwrap(fixture()["data_boc"] as? String)
        XCTAssertThrowsError(try TOSNativeWalletRPC.normalizeSnapshot(nonempty, address: wallet().address, expectedWallet: wallet()))
        var frozen = empty; frozen["state"] = "frozen"
        XCTAssertThrowsError(try TOSNativeWalletRPC.normalizeSnapshot(frozen, address: wallet().address, expectedWallet: wallet()))
    }

    func testTypedIdentityCannotBorrowAnotherNativeAccountsCounter() throws {
        let otherKey = Data(repeating: 7, count: 32)
        let other = try TOSWalletV5R1(publicKey: otherKey, networkGlobalId: 3)
        let otherAddress = try Address(workchain: 0, hash: Builder().store(other.stateInit).endCell().hash())
        var state = try snapshot(); state["data"] = try data(key: otherKey).toBoc().base64EncodedString()
        XCTAssertEqual(try TOSWalletRPC.decodeSeqno(TOSNativeWalletRPC.normalizeSnapshot(state, address: otherAddress)), 1)
        XCTAssertThrowsError(try TOSNativeWalletRPC.normalizeSnapshot(state, address: otherAddress, expectedWallet: wallet()))
    }

    func testCompatibilityKeepsTheCapturedEndpointAcrossBothReads() async throws {
        let fixture = try fixture(); let snapshot = try snapshot(); var endpoints = 0; var hosts = [String]()
        NativeRPCURLProtocol.handler = { request in
            hosts.append(try XCTUnwrap(request.url?.host))
            let method = try XCTUnwrap(Self.request(request)["method"] as? String)
            return try Self.response(method == "getWalletInformation" ? XCTUnwrap(fixture["wallet_information"] as? [String: Any]) : snapshot)
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [NativeRPCURLProtocol.self]
        let node = TOSRPCClient(basePath: { endpoints += 1; return endpoints == 1 ? "http://original.test" : "http://replacement.test" }, urlSession: URLSession(configuration: configuration))
        let info = try await node.walletInformation(address: wallet().address)
        XCTAssertEqual(try TOSWalletRPC.decodeSeqno(info), 1)
        XCTAssertEqual(endpoints, 1); XCTAssertEqual(hosts, ["original.test", "original.test"])
    }
}

private final class NativeRPCURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
