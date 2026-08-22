import Foundation
import TonSwift

public protocol RecipientResolver {
    func resolverRecipient(string: String, network: Network) async throws -> Recipient
    func resolverTonRecipient(string: String, network: Network) async throws -> TonRecipient
}

public struct RecipientResolverImplementation: RecipientResolver {
    public enum Error: Swift.Error {
        case failedResolve(string: String)
        case incorrectNet(sender: Network, recipient: Network)
    }

    private let dnsService: DNSService
    private let accountService: AccountService

    init(
        dnsService: DNSService,
        accountService: AccountService
    ) {
        self.dnsService = dnsService
        self.accountService = accountService
    }

    public func resolverRecipient(string: String, network: Network) async throws -> Recipient {
        if let tronRecipient = resolveTronRecipient(string: string) {
            return .tron(tronRecipient)
        }

        return try .ton(await resolverTonRecipient(string: string, network: network))
    }

    public func resolverTonRecipient(string: String, network: Network) async throws -> TonRecipient {
        if let friendlyAddress = try? FriendlyAddress(string: string) {
            guard friendlyAddress.isTestOnly == (network == .testnet) else {
                throw Error.incorrectNet(
                    sender: network,
                    recipient: friendlyAddress.isTestOnly ? .testnet : .mainnet
                )
            }

            let account = try await getAccount(
                for: friendlyAddress.address,
                network: network
            )

            return TonRecipient(
                recipientAddress: .friendly(friendlyAddress),
                isMemoRequired: account.isMemoRequired == true,
                isScam: account.isScam == true
            )
        } else if let address = try? Address.parse(string) {
            let account = try await getAccount(
                for: address,
                network: network
            )

            return TonRecipient(
                recipientAddress: .raw(address),
                isMemoRequired: account.isMemoRequired == true,
                isScam: account.isScam == true
            )
        } else if string.lowercased().hasSuffix(".tos") {
            // Never ask the inherited account API to interpret a domain. The
            // TOS resolver binds every hop and lifecycle getter to one
            // finalized checkpoint before this address is used for payment.
            let domain = try await dnsService.resolveDomainName(string, network: network)
            let account = try await getAccount(for: domain.friendlyAddress.address, network: network)

            return TonRecipient(
                recipientAddress: .domain(domain),
                isMemoRequired: account.isMemoRequired == true,
                isScam: account.isScam == true
            )
        } else {
            throw Error.failedResolve(string: string)
        }
    }

    private func resolveTronRecipient(string: String) -> TronRecipient? {
        try? TronRecipient(address: string)
    }

    private func getAccount(for address: Address, network: Network) async throws -> Account {
        try await accountService.loadAccount(network: network, address: address)
    }
}
