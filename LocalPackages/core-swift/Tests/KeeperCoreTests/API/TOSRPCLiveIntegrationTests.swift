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
        let before = try await validatorViews(clients)
        assertConverged(before)

        let expectedAfterBalance = try await requestLocalnetTransfer(amount: 0.25)
        let deadline = Date().addingTimeInterval(30)
        var after = try await validatorViews(clients)
        while Date() < deadline && (
            Set(after.balances).count != 1 || after.balances[0] <= before.balances[0]
                || Set(after.eventIDs).count != 1 || after.eventIDs[0].count != before.eventIDs[0].count + 1
        ) {
            try await Task.sleep(nanoseconds: 500_000_000)
            after = try await validatorViews(clients)
        }
        assertConverged(after)
        XCTAssertEqual(after.balances[0], expectedAfterBalance)
        XCTAssertEqual(after.eventIDs[0].count, before.eventIDs[0].count + 1)
    }

    func testAccountEventPaginationHasNoDuplicatesOrGaps() async throws {
        let client = try await makeLiveClient()
        let complete = try await client.call(
            method: "getAccountEvents",
            params: ["address": Self.deterministicWalletAddress, "limit": 100]
        )
        let completeRows = try XCTUnwrap(complete["events"] as? [[String: Any]])
        let expected = completeRows.compactMap { $0["event_id"] as? String }
        XCTAssertFalse(expected.isEmpty)

        var cursor: String?
        var paged = [String]()
        repeat {
            var params: [String: Any] = ["address": Self.deterministicWalletAddress, "limit": 1]
            if let cursor { params["before_lt"] = cursor }
            let page = try await client.call(method: "getAccountEvents", params: params)
            let rows = try XCTUnwrap(page["events"] as? [[String: Any]])
            paged.append(contentsOf: rows.compactMap { $0["event_id"] as? String })
            cursor = page["next_from"] as? String
        } while cursor != nil

        XCTAssertEqual(paged, expected)
        XCTAssertEqual(Set(paged).count, paged.count)
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
            do {
                let (_, response) = try await URLSession.shared.data(from: readyURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw XCTSkip("Validator RPC is not healthy at \(validatorURL)")
                }
            } catch let skip as XCTSkip {
                throw skip
            } catch {
                throw XCTSkip("No validator RPC at \(validatorURL): \(error.localizedDescription)")
            }
            return TOSRPCClient(basePath: { validatorURL }, urlSession: .shared)
        }
    }

    private func validatorViews(_ clients: [TOSRPCClient]) async throws -> (
        balances: [UInt64], eventIDs: [Set<String>], seqnos: [Int]
    ) {
        var balances = [UInt64]()
        var eventIDs = [Set<String>]()
        var seqnos = [Int]()
        for client in clients {
            let account = try await client.call(
                method: "getAddressInformation",
                params: ["address": Self.deterministicWalletAddress]
            )
            balances.append(try XCTUnwrap(UInt64(try XCTUnwrap(account["balance"] as? String))))
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
        return (balances, eventIDs, seqnos)
    }

    private func assertConverged(
        _ views: (balances: [UInt64], eventIDs: [Set<String>], seqnos: [Int]),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(Set(views.balances).count, 1, file: file, line: line)
        XCTAssertEqual(Set(views.eventIDs).count, 1, file: file, line: line)
        XCTAssertLessThanOrEqual((views.seqnos.max() ?? 0) - (views.seqnos.min() ?? 0), 1, file: file, line: line)
    }

    private func requestLocalnetTransfer(amount: Double) async throws -> UInt64 {
        let endpoint = ProcessInfo.processInfo.environment["TOS_LOCALNET_CONTROL_URL"]
            ?? "http://127.0.0.1:18745"
        let url = try XCTUnwrap(URL(string: endpoint + "/transfer"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "address": Self.deterministicWalletAddress,
            "amount": amount,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(UInt64(try XCTUnwrap(object["after"] as? String)))
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
