import XCTest
@testable import TKAgentCommerce

/// Decodes the SAME shared spending-policy vector the Go servicebridge.PolicyEngine
/// is verified against, so the Swift owner-authorization is proven identical to
/// the canonical engine and to the Android client.
final class SpendingPolicyTests: XCTestCase {

    private struct Vectors: Decodable {
        let schema: String
        let nowUnix: UInt64
        let policyBase: PolicyFields
        let proposalBase: ProposalFields
        let cases: [Case]
    }
    private struct Case: Decodable {
        let name: String
        let policy: PolicyFields?
        let proposal: ProposalFields?
        let spentInWindowAtomic: String
        let expect: String
    }
    private struct PolicyFields: Decodable {
        let assetMaster: String?
        let assetWalletCodeHash: String?
        let maxAtomicPurchase: String?
        let dailyBudgetAtomic: String?
        let windowSeconds: UInt64?
        let expiryUnix: UInt64?
        let capabilityAllow: [String]?
        let confirmationMode: String?
        let hasOwnerSignature: Bool?
    }
    private struct ProposalFields: Decodable {
        let assetMaster: String?
        let assetWalletCodeHash: String?
        let maxAtomicAmount: String?
        let capabilityId: String?
    }

    private func atomic(_ value: String) throws -> UInt64 { try parseAtomicAmount(value) }

    private func resolvePolicy(_ base: PolicyFields, _ over: PolicyFields?) throws -> SpendingPolicy {
        SpendingPolicy(
            assetMaster: over?.assetMaster ?? base.assetMaster!,
            assetWalletCodeHash: over?.assetWalletCodeHash ?? base.assetWalletCodeHash!,
            maxAtomicPurchase: try atomic(over?.maxAtomicPurchase ?? base.maxAtomicPurchase!),
            dailyBudgetAtomic: try atomic(over?.dailyBudgetAtomic ?? base.dailyBudgetAtomic!),
            windowSeconds: over?.windowSeconds ?? base.windowSeconds!,
            expiryUnix: over?.expiryUnix ?? base.expiryUnix!,
            capabilityAllow: Set(over?.capabilityAllow ?? base.capabilityAllow!),
            confirmationMode: over?.confirmationMode ?? base.confirmationMode!,
            hasOwnerSignature: over?.hasOwnerSignature ?? base.hasOwnerSignature!
        )
    }

    private func resolveProposal(_ base: ProposalFields, _ over: ProposalFields?) throws -> QuoteFacts {
        QuoteFacts(
            assetMaster: over?.assetMaster ?? base.assetMaster!,
            assetWalletCodeHash: over?.assetWalletCodeHash ?? base.assetWalletCodeHash!,
            capabilityID: over?.capabilityId ?? base.capabilityId!,
            maxAtomicAmount: try atomic(over?.maxAtomicAmount ?? base.maxAtomicAmount!)
        )
    }

    func testAuthorizeMatchesSharedVectors() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "mobile_buyer_spending_policy_v1", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let vectors = try decoder.decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertEqual(vectors.schema, "tos.service.mobile-buyer-spending-policy.v1")

        for testCase in vectors.cases {
            let policy = try resolvePolicy(vectors.policyBase, testCase.policy)
            let proposal = try resolveProposal(vectors.proposalBase, testCase.proposal)
            let spent = try atomic(testCase.spentInWindowAtomic)
            let reason = SpendingPolicyEngine.authorize(policy, proposal, spentInWindow: spent, nowUnix: vectors.nowUnix)
            XCTAssertEqual(reason.rawValue, testCase.expect, testCase.name)
        }
    }
}
