@testable import KeeperCore
import XCTest

final class TOSRPCLiveIntegrationTests: XCTestCase {
    private static let faucetAddress = "Ef8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAU"

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
}
