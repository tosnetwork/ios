@testable import KeeperCore
import XCTest

final class TOSRPCLiveIntegrationTests: XCTestCase {
    private static let faucetAddress = "Ef8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAU"
    private static let deterministicWalletAddress = "UQCJFahawZUzYka4uzFTeWns-oQNfoa0VNVOAn8e8BJnXPZe"

    func testThreeNodeRPCReportsFundedFaucetAndAdvancingMasterchain() async throws {
        let client = try await makeLiveClient()

        let account = try await client.call(
            method: "getAddressInformation",
            params: ["address": Self.faucetAddress]
        )
        let balance = try XCTUnwrap(account["balance"] as? String)
        XCTAssertGreaterThan(try XCTUnwrap(UInt64(balance)), 0)
        XCTAssertEqual(account["state"] as? String, "active")

        let firstInfo = try await client.call(method: "getMasterchainInfo")
        let firstLast = try XCTUnwrap(firstInfo["last"] as? [String: Any])
        let firstSeqno = try XCTUnwrap(firstLast["seqno"] as? Int)

        try await Task.sleep(nanoseconds: 2_000_000_000)

        let secondInfo = try await client.call(method: "getMasterchainInfo")
        let secondLast = try XCTUnwrap(secondInfo["last"] as? [String: Any])
        let secondSeqno = try XCTUnwrap(secondLast["seqno"] as? Int)
        XCTAssertGreaterThanOrEqual(secondSeqno, firstSeqno)
    }

    func testThreeNodeRPCRejectsInvalidAddress() async throws {
        let client = try await makeLiveClient()

        do {
            _ = try await client.call(
                method: "getAddressInformation",
                params: ["address": "not-a-tos-address"]
            )
            XCTFail("Expected the node to reject an invalid address")
        } catch TOSRPCClient.Error.server {
            // Expected: proves errors from a live node reach the wallet unchanged.
        }
    }

    func testDeterministicIOSWalletAddressIsQueryable() async throws {
        let client = try await makeLiveClient()
        let account = try await client.call(
            method: "getAddressInformation",
            params: ["address": Self.deterministicWalletAddress]
        )

        XCTAssertNotNil(account["balance"] as? String)
        XCTAssertNotNil(account["state"] as? String)
    }

    func testAllThreeValidatorRPCViewsConverge() async throws {
        let clients = try await makeValidatorClients(count: 3)
        var balances = [String]()
        var eventIDs = [Set<String>]()
        var seqnos = [Int]()

        for client in clients {
            let account = try await client.call(
                method: "getAddressInformation",
                params: ["address": Self.deterministicWalletAddress]
            )
            balances.append(try XCTUnwrap(account["balance"] as? String))

            let events = try await client.call(
                method: "getAccountEvents",
                params: ["address": Self.deterministicWalletAddress, "limit": 100]
            )
            let rows = try XCTUnwrap(events["events"] as? [[String: Any]])
            eventIDs.append(Set(rows.compactMap { $0["event_id"] as? String }))

            let info = try await client.call(method: "getMasterchainInfo")
            let last = try XCTUnwrap(info["last"] as? [String: Any])
            seqnos.append(try XCTUnwrap(last["seqno"] as? Int))
        }

        XCTAssertEqual(Set(balances).count, 1)
        XCTAssertEqual(Set(eventIDs).count, 1)
        XCTAssertLessThanOrEqual((seqnos.max() ?? 0) - (seqnos.min() ?? 0), 1)
    }

    private func makeLiveClient() async throws -> TOSRPCClient {
        let value = ProcessInfo.processInfo.environment["TOS_LIVE_RPC_URL"] ?? "http://127.0.0.1:18545"
        let readyURL = try XCTUnwrap(URL(string: value + "/readyz"))
        do {
            let (_, response) = try await URLSession.shared.data(from: readyURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw XCTSkip("No healthy local TOS network at \(value)")
            }
        } catch {
            throw XCTSkip("No local TOS network at \(value): \(error.localizedDescription)")
        }
        return TOSRPCClient(basePath: { value }, urlSession: .shared)
    }

    private func makeValidatorClients(count: Int) async throws -> [TOSRPCClient] {
        let value = ProcessInfo.processInfo.environment["TOS_LIVE_RPC_URL"] ?? "http://127.0.0.1:18545"
        let baseURL = try XCTUnwrap(URL(string: value))
        let startPort = try XCTUnwrap(baseURL.port)
        return try await (0..<count).asyncMap { offset in
            var components = try XCTUnwrap(URLComponents(url: baseURL, resolvingAgainstBaseURL: false))
            components.port = startPort + offset
            let validatorURL = try XCTUnwrap(components.url?.absoluteString)
            let readyURL = try XCTUnwrap(URL(string: validatorURL + "/readyz"))
            let (_, response) = try await URLSession.shared.data(from: readyURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw XCTSkip("Validator RPC is not healthy at \(validatorURL)")
            }
            return TOSRPCClient(basePath: { validatorURL }, urlSession: .shared)
        }
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values = [T]()
        for element in self {
            values.append(try await transform(element))
        }
        return values
    }
}
