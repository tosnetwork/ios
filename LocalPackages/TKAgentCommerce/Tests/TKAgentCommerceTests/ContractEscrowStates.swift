import Foundation
import XCTest
@testable import TKAgentCommerce

/// Escrow states taken from the shared projection vectors: the named contract
/// cases are the fields of data cells the escrow v2 contract wrote.
enum ContractEscrowStates {
    static func state(_ name: String) throws -> EscrowRuntimeState {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "mobile_buyer_escrow_projection_v2", withExtension: "json"))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let found = try XCTUnwrap(cases.first { $0["name"] as? String == name }, "missing case \(name)")
        let escrow = try XCTUnwrap(found["escrow"] as? [String: Any], "case \(name) has no escrow")
        return EscrowRuntimeState(
            status: try XCTUnwrap((escrow["status"] as? NSNumber)?.uint8Value),
            quoteCommitment: try XCTUnwrap(escrow["quote_commitment"] as? String),
            fundedAtomicAmount: try XCTUnwrap(escrow["funded_atomic_amount"] as? String),
            settledAtomicAmount: try XCTUnwrap(escrow["settled_atomic_amount"] as? String),
            receiptCommitment: try XCTUnwrap(escrow["receipt_commitment"] as? String),
            acceptedAtUnix: try XCTUnwrap((escrow["accepted_at_unix"] as? NSNumber)?.uint64Value),
            pendingQueryID: try XCTUnwrap((escrow["pending_query_id"] as? NSNumber)?.uint64Value))
    }

    /// The contract's funded state with a different funded amount: still a
    /// consistent funded escrow, but not funded at the quoted amount.
    static func funded(atomic: String) throws -> EscrowRuntimeState {
        let funded = try state("funded")
        return EscrowRuntimeState(
            status: funded.status, quoteCommitment: funded.quoteCommitment,
            fundedAtomicAmount: atomic, settledAtomicAmount: funded.settledAtomicAmount,
            receiptCommitment: funded.receiptCommitment, acceptedAtUnix: funded.acceptedAtUnix,
            pendingQueryID: funded.pendingQueryID)
    }
}
