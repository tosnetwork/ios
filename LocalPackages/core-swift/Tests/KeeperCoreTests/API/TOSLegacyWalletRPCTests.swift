@testable import KeeperCore
import Foundation
import TonSwift
import XCTest

final class TOSLegacyWalletRPCTests: XCTestCase {
    override func tearDown() {
        LegacyRPCURLProtocol.handler = nil
        TOSRPCConnectivity.setUnavailable(false)
        super.tearDown()
    }

    func testFiveFrozenActiveSnapshotsBindOriginalCodeKeysIDsAndAddresses() throws {
        for fixture in try fixtures() {
            let wallet = try makeWallet(fixture)
            let address = try Address.parse(fixture.address)
            XCTAssertEqual(try wallet.address, address, fixture.revision)
            let information = try TOSLegacyWalletRPC.normalizeSnapshot(fixture.snapshot, address: address, expectedWallet: wallet)
            XCTAssertEqual(try TOSWalletRPC.decodeSeqno(information), 1, fixture.revision)
            XCTAssertTrue(information["wallet"] as? Bool == true)
            XCTAssertEqual(information["balance"] as? String, fixture.snapshot["balance"] as? String)
            XCTAssertEqual((information["last_transaction_id"] as? [String: String])?["hash"], (fixture.snapshot["last_transaction_id"] as? [String: String])?["hash"])
            let generic = try TOSLegacyWalletRPC.normalizeSnapshot(fixture.snapshot, address: address)
            XCTAssertEqual(try TOSWalletRPC.decodeSeqno(generic), 1)
            XCTAssertThrowsError(try TOSWalletRPC.decodeSeqno(fixture.information), "The actual node falsely classifies \(fixture.revision)")
        }
    }

    func testTypedMetadataRejectsWrongRevisionKeyAndLegacyNetwork() throws {
        let fixture = try XCTUnwrap(fixtures().last)
        let address = try Address.parse(fixture.address)
        for wallet in [
            try makeWallet(fixture, version: .v4R2),
            try makeWallet(fixture, publicKey: Data(repeating: 7, count: 32)),
            try makeWallet(fixture, network: .testnet),
            try makeWallet(fixture, version: .tosV5R1),
            try makeWallet(fixture, version: .v5Beta),
        ] {
            XCTAssertThrowsError(try TOSLegacyWalletRPC.normalizeSnapshot(fixture.snapshot, address: address, expectedWallet: wallet))
        }
    }

    func testImmutablePublicKeyWalletIDOrAddressCannotReuseOriginalAccount() throws {
        for fixture in try fixtures() {
            let address = try Address.parse(fixture.address)
            for (key, walletID) in [(Data(repeating: 0, count: 32), fixture.walletID), (try XCTUnwrap(Data(hex: fixture.publicKey)), fixture.walletID ^ 1)] {
                let data = try makeData(fixture, walletID: walletID, publicKey: key)
                var snapshot = fixture.snapshot
                snapshot["data"] = try data.toBoc().base64EncodedString()
                XCTAssertThrowsError(try TOSLegacyWalletRPC.normalizeSnapshot(snapshot, address: address), fixture.revision)
            }
            XCTAssertThrowsError(try TOSLegacyWalletRPC.normalizeSnapshot(fixture.snapshot, address: Address(workchain: 0, hash: Data(repeating: 0, count: 32))))
        }
    }

    func testDisabledV5SignatureAuthorizationCannotUseEd25519SendPath() throws {
        let fixture = try XCTUnwrap(fixtures().last)
        var snapshot = fixture.snapshot
        snapshot["data"] = try makeData(fixture, signatureAllowed: false).toBoc().base64EncodedString()
        XCTAssertThrowsError(try TOSLegacyWalletRPC.normalizeSnapshot(snapshot, address: Address.parse(fixture.address), expectedWallet: makeWallet(fixture)))
    }

    func testMalformedUnknownFrozenAndTrailingStateFailsClosed() throws {
        let multipleRoots = try XCTUnwrap(Data(hex: "b5ee9c72010102020004000100000000"))
        XCTAssertEqual(try Cell.fromBoc(src: multipleRoots).count, 2)
        let beta = try makeWallet(XCTUnwrap(fixtures().last), version: .v5Beta)
        let exoticCode = try TOSLegacyWalletRPC.initialComponents(wallet: beta).code
        XCTAssertTrue(exoticCode.isExotic)
        let emptyCell = try Builder().endCell()
        let malformedBOCs = try TOSRPCBOCTestFixtures.malformedBase64()
        for fixture in try fixtures() {
            let address = try Address.parse(fixture.address)
            let data = try Cell.fromBase64(src: XCTUnwrap(fixture.snapshot["data"] as? String))
            let extraBits = try Builder().store(slice: data.beginParse()).store(bit: false).endCell()
            let extraRefs = try Builder().store(slice: data.beginParse()).store(ref: Builder()).endCell()
            var invalidStates = [[String: Any]]()
            for key in ["code", "data"] {
                for value in ["not-base64", "", try emptyCell.toBoc().base64EncodedString(), multipleRoots.base64EncodedString(), try exoticCode.toBoc().base64EncodedString()] + malformedBOCs {
                    var snapshot = fixture.snapshot
                    snapshot[key] = value
                    invalidStates.append(snapshot)
                }
            }
            for cell in [extraBits, extraRefs] {
                var snapshot = fixture.snapshot
                snapshot["data"] = try cell.toBoc().base64EncodedString()
                invalidStates.append(snapshot)
            }
            var frozen = fixture.snapshot
            frozen["state"] = "frozen"
            invalidStates.append(frozen)
            var missing = fixture.snapshot
            missing.removeValue(forKey: "state")
            invalidStates.append(missing)
            for snapshot in invalidStates {
                XCTAssertThrowsError(try TOSLegacyWalletRPC.normalizeSnapshot(snapshot, address: address), fixture.revision)
            }
        }
    }

    func testActiveCounterBoundsAndExtensionRootShape() throws {
        for fixture in try fixtures() {
            for seqno in [UInt32(0), UInt32.max] {
                var snapshot = fixture.snapshot
                snapshot["data"] = try makeData(fixture, seqno: seqno).toBoc().base64EncodedString()
                let information = try TOSLegacyWalletRPC.normalizeSnapshot(snapshot, address: Address.parse(fixture.address), expectedWallet: makeWallet(fixture))
                XCTAssertEqual(try TOSWalletRPC.decodeSeqno(information), seqno)
            }
            if !fixture.revision.hasPrefix("v3") {
                var snapshot = fixture.snapshot
                let extensionRoot = try Builder().store(bit: false).endCell()
                snapshot["data"] = try makeData(fixture, extensionRoot: extensionRoot).toBoc().base64EncodedString()
                XCTAssertNoThrow(try TOSLegacyWalletRPC.normalizeSnapshot(snapshot, address: Address.parse(fixture.address), expectedWallet: makeWallet(fixture)))
                // Presence without its required reference must not parse.
                let malformed = try makeDataBuilder(fixture).store(bit: true).endCell()
                snapshot["data"] = try malformed.toBoc().base64EncodedString()
                XCTAssertThrowsError(try TOSLegacyWalletRPC.normalizeSnapshot(snapshot, address: Address.parse(fixture.address)))
            }
        }
    }

    func testOnlyEmptyExplicitUninitializedStateMayBecomeDeploymentZero() throws {
        let fixture = try XCTUnwrap(fixtures().first)
        let wallet = try makeWallet(fixture)
        let address = try wallet.address
        let empty: [String: Any] = ["state": "uninitialized", "code": "", "data": ""]
        XCTAssertEqual(try TOSWalletRPC.decodeSeqno(TOSLegacyWalletRPC.normalizeSnapshot(empty, address: address, expectedWallet: wallet)), 0)
        for key in ["code", "data"] {
            var nonempty = empty
            nonempty[key] = fixture.snapshot[key]
            XCTAssertThrowsError(try TOSLegacyWalletRPC.normalizeSnapshot(nonempty, address: address, expectedWallet: wallet))
        }
        XCTAssertThrowsError(try TOSLegacyWalletRPC.normalizeSnapshot(["state": "active", "code": "", "data": ""], address: address))
    }

    func testAddressOnlyFallbackStaysOnEndpointCapturedBeforeAwait() async throws {
        let fixture = try XCTUnwrap(fixtures().last)
        var endpoint = "http://verified.test"
        var methods = [String]()
        LegacyRPCURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "verified.test")
            let method = try XCTUnwrap(Self.requestBody(request)["method"] as? String)
            methods.append(method)
            if method == "getWalletInformation" {
                endpoint = "http://edited.test"
                return try Self.response(fixture.information)
            }
            XCTAssertEqual(method, "getAddressInformation")
            return try Self.response(fixture.snapshot)
        }
        let client = makeClient(endpoint: { endpoint })
        let information = try await client.walletInformation(address: Address.parse(fixture.address))
        XCTAssertEqual(try TOSWalletRPC.decodeSeqno(information), 1)
        XCTAssertEqual(methods, ["getWalletInformation", "getAddressInformation"])
        XCTAssertEqual(endpoint, "http://edited.test")
    }

    func testAddressOnlyActiveFallbackCannotBecomeUninitializedDeployment() async throws {
        let fixture = try XCTUnwrap(fixtures().last)
        var methods = [String]()
        LegacyRPCURLProtocol.handler = { request in
            let method = try XCTUnwrap(Self.requestBody(request)["method"] as? String)
            methods.append(method)
            if method == "getWalletInformation" {
                return try Self.response(fixture.information)
            }
            XCTAssertEqual(method, "getAddressInformation")
            return try Self.response(["state": "uninitialized", "code": "", "data": ""])
        }
        do {
            _ = try await makeClient().walletInformation(address: Address.parse(fixture.address))
            XCTFail("Address-only active fallback must not supply deployment zero from an empty snapshot")
        } catch {
            guard case TOSRPCClient.Error.invalidResponse = error else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
            XCTAssertEqual(methods, ["getWalletInformation", "getAddressInformation"])
        }
    }

    func testTypedLegacyReadsOneRawSnapshotWithoutNullWalletGetter() async throws {
        for fixture in try fixtures() {
            var calls = 0
            LegacyRPCURLProtocol.handler = { request in
                calls += 1
                XCTAssertEqual(try Self.requestBody(request)["method"] as? String, "getAddressInformation")
                return try Self.response(fixture.snapshot)
            }
            let information = try await makeClient().walletInformation(wallet: makeWallet(fixture))
            XCTAssertEqual(try TOSWalletRPC.decodeSeqno(information), 1, fixture.revision)
            XCTAssertEqual(calls, 1)
        }
    }

    func testFiveLegacyFeeProfilesKeepEndpointAndOnlyUninitializedInit() async throws {
        for fixture in try fixtures() {
            for deployment in [false, true] {
                var endpoint = "http://verified.test"
                var methods = [String]()
                LegacyRPCURLProtocol.handler = { request in
                    XCTAssertEqual(request.url?.host, "verified.test")
                    let body = try Self.requestBody(request)
                    let method = try XCTUnwrap(body["method"] as? String)
                    methods.append(method)
                    if method == "getAddressInformation" {
                        endpoint = "http://edited.test"
                        return try Self.response(deployment ? ["state": "uninitialized", "code": "", "data": ""] : fixture.snapshot)
                    }
                    XCTAssertEqual(method, "estimateFee")
                    let params = try XCTUnwrap(body["params"] as? [String: Any])
                    XCTAssertEqual(params["ignore_chksig"] as? Bool, true)
                    if deployment {
                        let code = try Cell.fromBase64(src: XCTUnwrap(params["init_code"] as? String))
                        XCTAssertEqual(code.hash().map { String(format: "%02x", $0) }.joined(), fixture.codeHash)
                        let data = try Cell.fromBase64(src: XCTUnwrap(params["init_data"] as? String))
                        XCTAssertEqual(data.hash(), try Cell.fromBase64(src: fixture.initialDataBOC).hash())
                    } else {
                        XCTAssertNil(params["init_code"])
                        XCTAssertNil(params["init_data"])
                    }
                    return try Self.response(["source_fees": ["in_fwd_fee": "1", "storage_fee": "2", "gas_fee": "3", "fwd_fee": "4"]])
                }
                let fee = try await makeClient(endpoint: { endpoint }).estimateWalletFee(body: "body", wallet: makeWallet(fixture))
                XCTAssertEqual(fee, 10)
                XCTAssertEqual(methods, ["getAddressInformation", "estimateFee"])
            }
        }
    }

    func testNativeAndBetaActiveNullNeverEnterLegacyFallback() async throws {
        let fixture = try XCTUnwrap(fixtures().last)
        for version in [WalletContractVersion.tosV5R1, .v5Beta] {
            var methods = [String]()
            LegacyRPCURLProtocol.handler = { request in
                let body = try Self.requestBody(request)
                let method = try XCTUnwrap(body["method"] as? String)
                methods.append(method)
                if method == "getConfigParam" {
                    let parameter = try XCTUnwrap((body["params"] as? [String: Int])?["param"])
                    let cell = parameter == 19 ? try Builder().store(int: 3, bits: 32).endCell() : try Builder().store(uint: 0xc4, bits: 8).store(uint: 18, bits: 32).store(uint: 0, bits: 64).endCell()
                    return try Self.response(["config": ["bytes": try cell.toBoc().base64EncodedString()]])
                }
                XCTAssertEqual(method, "getWalletInformation")
                return try Self.response(fixture.information)
            }
            let information = try await makeClient().walletInformation(wallet: makeWallet(fixture, version: version))
            XCTAssertThrowsError(try TOSWalletRPC.decodeSeqno(information))
            XCTAssertFalse(methods.contains("getAddressInformation"))
        }
    }

    func testGenericFallbackRequiresExplicitActiveFalseAndNullCounter() async throws {
        let fixture = try XCTUnwrap(fixtures().last)
        for change in [["seqno": "garbage"], ["wallet": true], ["account_state": "frozen"], ["seqno": 0]] as [[String: Any]] {
            var information = fixture.information
            information.merge(change) { _, new in new }
            var methods = [String]()
            LegacyRPCURLProtocol.handler = { request in
                methods.append(try XCTUnwrap(Self.requestBody(request)["method"] as? String))
                return try Self.response(information)
            }
            _ = try await makeClient().walletInformation(address: Address.parse(fixture.address))
            XCTAssertEqual(methods, ["getWalletInformation"])
        }
    }

    func testInvalidLegacyRawStateStopsBeforeFeeEstimation() async throws {
        let fixture = try XCTUnwrap(fixtures().last)
        for malformedData in ["", "malformed", try makeData(fixture, signatureAllowed: false).toBoc().base64EncodedString()] {
            var snapshot = fixture.snapshot
            snapshot["data"] = malformedData
            var methods = [String]()
            LegacyRPCURLProtocol.handler = { request in
                methods.append(try XCTUnwrap(Self.requestBody(request)["method"] as? String))
                return try Self.response(snapshot)
            }
            do {
                _ = try await makeClient().estimateWalletFee(body: "body", wallet: makeWallet(fixture))
                XCTFail("Malformed active state must never be estimated as deployment")
            } catch {
                XCTAssertEqual(methods, ["getAddressInformation"])
            }
        }
    }

    func testAddressOnlyUnknownAndNativeCodeCannotAcquireLegacyCounter() async throws {
        let fixture = try XCTUnwrap(fixtures().last)
        let native = try makeWallet(fixture, version: .tosV5R1)
        let nativeCode = try TOSLegacyWalletRPC.initialComponents(wallet: native).code
        let emptyCell = try Builder().endCell()
        for code in [emptyCell, nativeCode] {
            var snapshot = fixture.snapshot
            snapshot["code"] = try code.toBoc().base64EncodedString()
            var methods = [String]()
            LegacyRPCURLProtocol.handler = { request in
                let method = try XCTUnwrap(Self.requestBody(request)["method"] as? String)
                methods.append(method)
                return try Self.response(method == "getWalletInformation" ? fixture.information : snapshot)
            }
            do {
                _ = try await makeClient().walletInformation(address: Address.parse(fixture.address))
                XCTFail("Unknown/native active code must not use the legacy counter decoder")
            } catch {
                XCTAssertEqual(methods, ["getWalletInformation", "getAddressInformation"])
            }
        }
    }

    func testOrdinaryLegacyDeploymentInitBelongsOnlyToSenderExternalMessage() throws {
        let recipient = Address(workchain: 0, hash: Data(repeating: 0x4a, count: 32))
        for fixture in try fixtures() {
            let wallet = try makeWallet(fixture)
            for seqno in [UInt64(0), 1] {
                let transfer = try TonTransferBuilder.createWalletTransfer(wallet: wallet, seqno: seqno, value: 1_000_000, isMax: false, recipientAddress: recipient, isBounceable: false, comment: "Legacy deployment", timeout: 1_800_000_000, messageType: .ext)
                let unsigned = try transfer.signingMessage.endCell()
                let internalCell: Cell
                if fixture.revision == "v5R1" {
                    let action = try XCTUnwrap(unsigned.refs.first)
                    XCTAssertEqual(action.refs.count, 2)
                    internalCell = action.refs[1]
                } else {
                    internalCell = try XCTUnwrap(unsigned.refs.first)
                }
                let internalMessage = try MessageRelaxed.loadFrom(slice: internalCell.beginParse())
                XCTAssertNil(internalMessage.stateInit, "The sender's code must not deploy at its recipient")
                guard case let .internalInfo(info) = internalMessage.info else { return XCTFail("Expected internal transfer") }
                XCTAssertEqual(info.dest, recipient)
                let signed = try TransferSigner.signWalletTransfer(transfer.signingMessage, signaturePosition: transfer.signaturePosition, wallet: wallet, seqno: seqno, signed: Data(repeating: 0, count: 64))
                let external = try Message.loadFrom(slice: signed.beginParse())
                guard case let .externalInInfo(info) = external.info else { return XCTFail("Expected wallet external message") }
                XCTAssertEqual(info.dest, try wallet.address)
                if seqno == 0 {
                    let initial = try XCTUnwrap(external.stateInit)
                    XCTAssertEqual(try Builder().store(initial).endCell().hash(), try Builder().store(wallet.stateInit).endCell().hash())
                } else {
                    XCTAssertNil(external.stateInit, "An active legacy wallet must use its on-chain state")
                }
            }
        }
    }

    private struct Fixture {
        let revision: String
        let address: String
        let publicKey: String
        let walletID: UInt32
        let codeHash: String
        let initialDataBOC: String
        let snapshot: [String: Any]
        let information: [String: Any]
    }

    private func fixtures() throws -> [Fixture] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tos-legacy-wallet-rpc-snapshots", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(object["wallets"] as? [[String: Any]]).map { row in
            Fixture(revision: try XCTUnwrap(row["revision"] as? String), address: try XCTUnwrap(row["address"] as? String), publicKey: try XCTUnwrap(row["public_key"] as? String), walletID: try XCTUnwrap(row["wallet_id"] as? NSNumber).uint32Value, codeHash: try XCTUnwrap(row["code_hash"] as? String), initialDataBOC: try XCTUnwrap(row["initial_data_boc"] as? String), snapshot: try XCTUnwrap(row["snapshot"] as? [String: Any]), information: try XCTUnwrap(row["wallet_information"] as? [String: Any]))
        }
    }

    private func makeWallet(_ fixture: Fixture, version: WalletContractVersion? = nil, publicKey: Data? = nil, network: Network = .mainnet) throws -> Wallet {
        let revisions: [String: WalletContractVersion] = ["v3R1": .v3R1, "v3R2": .v3R2, "v4R1": .v4R1, "v4R2": .v4R2, "v5R1": .v5R1]
        let selected = try version ?? XCTUnwrap(revisions[fixture.revision])
        let key = try publicKey ?? XCTUnwrap(Data(hex: fixture.publicKey))
        return Wallet(id: "legacy-test", identity: WalletIdentity(network: network, kind: .Regular(PublicKey(data: key), selected), networkGlobalId: selected == .tosV5R1 ? 3 : nil), metaData: WalletMetaData(label: "Public fixture", tintColor: .defaultColor, icon: .icon(.wallet)), setupSettings: WalletSetupSettings(), batterySettings: BatterySettings())
    }

    private func makeDataBuilder(_ fixture: Fixture, seqno: UInt32 = 1, walletID: UInt32? = nil, publicKey: Data? = nil, signatureAllowed: Bool = true) throws -> Builder {
        let builder = Builder()
        if fixture.revision == "v5R1" { try builder.store(bit: signatureAllowed) }
        return try builder.store(uint: seqno, bits: 32).store(uint: walletID ?? fixture.walletID, bits: 32).store(data: publicKey ?? XCTUnwrap(Data(hex: fixture.publicKey)))
    }

    private func makeData(_ fixture: Fixture, seqno: UInt32 = 1, walletID: UInt32? = nil, publicKey: Data? = nil, signatureAllowed: Bool = true, extensionRoot: Cell? = nil) throws -> Cell {
        let builder = try makeDataBuilder(fixture, seqno: seqno, walletID: walletID, publicKey: publicKey, signatureAllowed: signatureAllowed)
        if !fixture.revision.hasPrefix("v3") { try builder.storeMaybe(ref: extensionRoot) }
        return try builder.endCell()
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

    private static func response(_ result: [String: Any]) throws -> (Int, String) {
        (200, try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: ["ok": true, "result": result]), encoding: .utf8)))
    }

    private func makeClient(endpoint: @escaping () async -> String = { "http://verified.test" }) -> TOSRPCClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LegacyRPCURLProtocol.self]
        return TOSRPCClient(basePath: endpoint, urlSession: URLSession(configuration: configuration))
    }
}

private final class LegacyRPCURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try XCTUnwrap(Self.handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
