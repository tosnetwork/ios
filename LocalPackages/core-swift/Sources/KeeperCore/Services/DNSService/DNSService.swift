import Foundation
import TonAPI
import TonSwift

public protocol DNSService {
    func resolveDomainName(_ domainName: String, addTonPostfix: Bool, network: Network) async throws -> Domain
    func loadDomainExpirationDate(_ domainName: String, network: Network) async throws -> Date?
    func inspectDomain(_ domainName: String, network: Network) async throws -> TOSDNSDomainState
}

public extension DNSService {
    func resolveDomainName(_ domainName: String, network: Network) async throws -> Domain {
        try await resolveDomainName(domainName, addTonPostfix: false, network: network)
    }
}

final class DNSServiceImplementation: DNSService {
    enum Error: Swift.Error {
        case noWalletData
    }

    private let apiProvider: APIProvider

    init(apiProvider: APIProvider) {
        self.apiProvider = apiProvider
    }

    func resolveDomainName(_ domainName: String, addTonPostfix: Bool, network: Network) async throws -> Domain {
        let normalizedDomainName = domainName.lowercased()
        let resolveName: String = {
            if addTonPostfix {
                return parseDomainName(normalizedDomainName)
            } else {
                return normalizedDomainName
            }
        }()

        guard resolveName.hasSuffix(".tos") else {
            throw TOSDNSError.invalidName("only the canonical .tos suffix is supported")
        }
        let api = apiProvider.api(network)
        let evidence = try await api.resolveTOSDomain(resolveName)
        let address = try Address.parse(evidence.resolvedAddress)
        let result = FriendlyAddress(
            address: address,
            testOnly: network == .testnet,
            bounceable: true
        )
        return Domain(domain: evidence.canonicalName, friendlyAddress: result, evidence: evidence)
    }

    func loadDomainExpirationDate(_ domainName: String, network: Network) async throws -> Date? {
        let evidence = try await apiProvider.api(network).resolveTOSDomain(domainName)
        return Date(timeIntervalSince1970: TimeInterval(evidence.renewalDeadline))
    }

    func inspectDomain(_ domainName: String, network: Network) async throws -> TOSDNSDomainState {
        try await apiProvider.api(network).inspectTOSDomain(domainName)
    }
}

private extension DNSServiceImplementation {
    func parseDomainName(_ domainName: String) -> String {
        guard let url = URL(string: domainName) else { return domainName }
        if url.pathExtension.isEmpty {
            return "\(domainName).tos"
        }
        return domainName
    }
}
