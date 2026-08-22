import BigInt
import Foundation
import OpenAPIRuntime
import TonAPI
import TonSwift

public extension Notification.Name {
    static let tosRPCUnavailable = Notification.Name("tos.rpc.unavailable")
    static let tosRPCAvailable = Notification.Name("tos.rpc.available")
}

public enum TOSRPCConnectivity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var unavailable = false

    public static var isUnavailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return unavailable
    }

    @discardableResult
    static func setUnavailable(_ value: Bool) -> Bool {
        lock.lock()
        let previous = unavailable
        unavailable = value
        lock.unlock()
        return previous
    }
}

public enum FetchError: Error {
    case wrongHost
    case unsupportedScheme
}

protocol APIHostProvider {
    var basePath: String { get async }
}

struct MainnetAPIHostProvider: APIHostProvider {
    private let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    var basePath: String {
        get async {
            if let environmentEndpoint = ProcessInfo.processInfo.environment["TOS_RPC_URL"] {
                return environmentEndpoint
            }
            if let customEndpoint = TOSRPCSettings.customEndpoint {
                return customEndpoint
            }
#if DEBUG
            return "http://127.0.0.1:18545"
#else
            return await configuration.tonapiV2Endpoint
#endif
        }
    }
}

struct TestnetAPIHostProvider: APIHostProvider {
    private let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    var basePath: String {
        get async {
            if let customEndpoint = TOSRPCSettings.customEndpoint {
                return customEndpoint
            }
            return await configuration.tonapiTestnetHost
        }
    }
}

struct TetraAPIHostProvider: APIHostProvider {
    private let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    var basePath: String {
        get async {
            if let customEndpoint = TOSRPCSettings.customEndpoint {
                return customEndpoint
            }
            return await configuration.tetraHost
        }
    }
}

struct TOSRPCClient {
    enum Error: Swift.Error, LocalizedError {
        case invalidEndpoint
        case invalidResponse
        case server(code: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "The TOS node endpoint is invalid."
            case .invalidResponse:
                return "The TOS node returned an invalid response."
            case let .server(code, message):
                return "TOS node error \(code): \(message)"
            }
        }
    }

    let basePath: () async -> String
    let urlSession: URLSession

    func call(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let attempts = isSafeToRetry(method: method) ? 2 : 1
        for attempt in 1 ... attempts {
            do {
                let result = try await callOnce(method: method, params: params)
                if TOSRPCConnectivity.setUnavailable(false) {
                    NotificationCenter.default.post(name: .tosRPCAvailable, object: nil)
                }
                return result
            } catch let error as URLError where attempt < attempts && isTransient(error) {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch let error as Error {
                // A well-formed JSON-RPC error proves that the node is reachable. It may
                // reject an address-specific operation (for example, wallet information
                // for an uninitialized recipient), but that must not put the whole wallet
                // into its offline state.
                if case .server = error {
                    if TOSRPCConnectivity.setUnavailable(false) {
                        NotificationCenter.default.post(name: .tosRPCAvailable, object: nil)
                    }
                } else {
                    TOSRPCConnectivity.setUnavailable(true)
                    NotificationCenter.default.post(name: .tosRPCUnavailable, object: nil)
                }
                throw error
            } catch {
                TOSRPCConnectivity.setUnavailable(true)
                NotificationCenter.default.post(name: .tosRPCUnavailable, object: nil)
                throw error
            }
        }
        preconditionFailure("TOS RPC retry loop exhausted without returning or throwing")
    }

    private func callOnce(method: String, params: [String: Any]) async throws -> [String: Any] {
        let basePath = await basePath().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let endpoint = URL(string: basePath + "/jsonRPC") else {
            throw Error.invalidEndpoint
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ])

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }
        let envelope: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Error.invalidResponse
            }
            envelope = object
        } catch {
            throw Error.invalidResponse
        }

        if envelope["ok"] as? Bool == false {
            throw Error.server(
                code: envelope["code"] as? Int ?? -32603,
                message: envelope["error"] as? String ?? "RPC error"
            )
        }
        if let error = envelope["error"] as? [String: Any] {
            throw Error.server(
                code: error["code"] as? Int ?? -32603,
                message: error["message"] as? String ?? "RPC error"
            )
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw Error.invalidResponse
        }
        guard let result = envelope["result"] as? [String: Any] else {
            throw Error.invalidResponse
        }
        return result
    }

    private func isSafeToRetry(method: String) -> Bool {
        method != "sendBoc" && method != "sendBocReturnHash"
    }

    private func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }
}

public struct API {
    private let hostProvider: APIHostProvider
    private let urlSession: URLSession
    private let configuration: Configuration
    private let requestCreationQueue: DispatchQueue

    init(
        hostProvider: APIHostProvider,
        urlSession: URLSession,
        configuration: Configuration,
        requestCreationQueue: DispatchQueue
    ) {
        self.hostProvider = hostProvider
        self.urlSession = urlSession
        self.configuration = configuration
        self.requestCreationQueue = requestCreationQueue
    }

    private func createRequest<T>(requestCreation: () -> RequestBuilder<T>) async throws -> RequestBuilder<T> {
        let apiKey = await configuration.tonApiV2Key
        let hostUrl = await hostProvider.basePath
        return requestCreationQueue.sync {
            TonAPIAPI.basePath = hostUrl
            var request = requestCreation()
            request = request.addHeader(name: "Authorization", value: "Bearer \(apiKey)")
            return request
        }
    }

    enum Error: Swift.Error {
        case failed
    }

    func tosRPCCall(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        try await TOSRPCClient(
            basePath: { await hostProvider.basePath },
            urlSession: urlSession
        ).call(method: method, params: params)
    }

    private func integer(_ value: Any?) -> Int64 {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) ?? 0 }
        return 0
    }

    @discardableResult
    private func performRequest<T>(request: RequestBuilder<T>, count: Int = 0, delay: UInt64 = 500_000_000) async throws -> Response<T> {
        do {
            return try await request.execute()
        } catch {
            if let errorResponse = error as? ErrorResponse {
                switch errorResponse {
                case let .error(statusCode, _, _, _):
                    if statusCode == 429 {
                        try await Task.sleep(nanoseconds: delay * UInt64(count))
                        try Task.checkCancellation()
                        return try await performRequest(request: request, count: count + 1, delay: delay)
                    }
                    throw errorResponse
                }
            } else {
                throw error
            }
        }
    }
}

// MARK: - For Dapp bridge

extension API {
    func tonapiFetch(url: String, options: [String: Any]?) async throws -> (Data, URLResponse) {
        let uri = URL(string: url)
        if uri?.scheme != "https" {
            throw FetchError.unsupportedScheme
        }
        let host = uri?.host
        if host != "tos.network", host?.hasSuffix(".tos.network") == false {
            throw FetchError.wrongHost
        }

        var builder = URLRequest(url: uri!)

        let methodOptions = options?["method"] as? String ?? "GET"
        let headersOptions = options?["headers"] as? [String: String] ?? [:]
        let bodyOptions = options?["body"] as? String ?? ""
        var contentTypeOptions = "application/json"

        for (key, value) in headersOptions {
            if key == "Authorization" {
                builder.setValue(value, forHTTPHeaderField: "X-Authorization")
            } else if key == "Content-Type" {
                contentTypeOptions = value
            } else {
                builder.setValue(value, forHTTPHeaderField: key)
            }
        }

        let apiKey = await configuration.tonApiV2Key
        builder.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        if methodOptions == "POST" {
            builder.httpBody = bodyOptions.data(using: .utf8)
            builder.setValue(contentTypeOptions, forHTTPHeaderField: "Content-Type")
            builder.httpMethod = "POST"
        }

        return try await urlSession.data(for: builder)
    }
}

// MARK: - Account

extension API {
    func getAccountInfo(accountId: String) async throws -> Account {
        let response = try await tosRPCCall(
            method: "getAddressInformation",
            params: ["address": accountId]
        )
        let walletInfo = try? await tosRPCCall(
            method: "getWalletInformation",
            params: ["address": accountId]
        )
        let code = response["code"] as? String
        return Account(
            address: try Address.parse(accountId),
            balance: integer(response["balance"]),
            status: response["state"] as? String ?? (code?.isEmpty == false ? "active" : "uninit"),
            name: nil,
            icon: nil,
            isSuspended: false,
            isWallet: walletInfo?["wallet"] as? Bool ?? walletInfo?["is_wallet"] as? Bool ?? false,
            isScam: false,
            isMemoRequired: false
        )
    }

    func getAccountJettonsBalances(address: Address, currencies: [Currency]) async throws -> [JettonBalance] {
        let response = try await tosRPCCall(
            method: "getAccountJettons",
            params: ["address": address.toRaw(), "limit": 1_000]
        )
        guard let entries = response["jettons"] as? [[String: Any]] else {
            throw TOSRPCClient.Error.invalidResponse
        }
        var balances = [JettonBalance]()
        for entry in entries {
            guard let walletRaw = entry["jetton_wallet"] as? String,
                  let masterRaw = entry["jetton_master"] as? String,
                  let walletAddress = try? Address.parse(walletRaw),
                  let masterAddress = try? Address.parse(masterRaw)
            else { continue }
            guard let quantity = try? await tosJettonWalletBalance(walletRaw), quantity > 0,
                  let info = try? await tosJettonInfo(masterAddress) else { continue }
            balances.append(JettonBalance(
                item: JettonItem(jettonInfo: info, walletAddress: walletAddress),
                quantity: quantity,
                rates: [:]
            ))
        }
        return balances
    }

    private func mapJettonRates(rates: TokenRates?) -> [Currency: Rates.Rate] {
        var result = [Currency: Rates.Rate]()
        rates?.prices?.forEach { currencyCode, value in
            guard let currency = Currency(code: currencyCode) else { return }
            let rate = Decimal(value)
            let diff24h = rates?.diff24h?.first(where: { $0.key == currencyCode })?.value
            result[currency] = Rates.Rate(currency: currency, rate: rate, diff24h: diff24h)
        }
        return result
    }
}

//// MARK: - Events

extension API {
    func getAccountEvents(
        address: Address,
        beforeLt: Int64?,
        limit: Int
    ) async throws -> AccountEvents {
        var params: [String: Any] = ["address": address.toRaw(), "limit": limit]
        if let beforeLt { params["before_lt"] = String(beforeLt) }
        let response = try await tosRPCCall(method: "getAccountEvents", params: params)
        let events = try TOSAccountHistoryMapper.events(response["events"], account: address)
        return AccountEvents(
            address: address,
            events: events,
            startFrom: beforeLt ?? 0,
            nextFrom: TOSAccountHistoryMapper.int64(response["next_from"]) ?? 0
        )
    }

    func getAccountJettonEvents(
        address: Address,
        jettonMasterAddress: Address,
        beforeLt: Int64?,
        limit: Int
    ) async throws -> AccountEvents {
        let request = try await createRequest {
            AccountsAPI.getAccountJettonHistoryByIDWithRequestBuilder(
                accountId: address.toRaw(),
                jettonId: jettonMasterAddress.toRaw(),
                limit: limit,
                beforeLt: beforeLt,
                startDate: nil,
                endDate: nil
            )
        }

        let response = try await performRequest(request: request).body
        let events: [AccountEvent] = response.events.compactMap {
            guard let activityEvent = try? AccountEvent(accountEvent: $0) else { return nil }
            return activityEvent
        }
        return AccountEvents(
            address: address,
            events: events,
            startFrom: beforeLt ?? 0,
            nextFrom: response.nextFrom
        )
    }

    func getEvent(
        address: Address,
        eventId: String
    ) async throws -> AccountEvent {
        let response = try await tosRPCCall(
            method: "getAccountEvent",
            params: ["address": address.toRaw(), "event_id": eventId]
        )
        return try TOSAccountHistoryMapper.event(response, account: address)
    }
}

// MARK: - Wallet

extension API {
    func getSeqno(address: Address) async throws -> Int {
        let response = try await tosRPCCall(
            method: "getWalletInformation",
            params: ["address": address.toRaw()]
        )
        return Int(integer(response["seqno"]))
    }

    func getWalletInfo(address: Address) async throws -> WalletInfo {
        let response = try await tosRPCCall(
            method: "getWalletInformation",
            params: ["address": address.toRaw()]
        )
        return WalletInfo(
            address: address,
            isWallet: response["wallet"] as? Bool ?? response["is_wallet"] as? Bool ?? false,
            balance: integer(response["balance"]),
            plugins: [],
            lastActivity: integer((response["last_transaction_id"] as? [String: Any])?["lt"])
        )
    }

    func emulateMessageWallet(
        boc: String,
        params: [EmulateMessageToWalletRequestParamsInner]?,
        currency: String? = nil
    ) async throws -> MessageConsequences {
        let request = try await createRequest {
            EmulationAPI.emulateMessageToWalletWithRequestBuilder(
                emulateMessageToWalletRequest: EmulateMessageToWalletRequest(boc: boc, params: params),
                currency: currency
            )
        }

        return try await performRequest(request: request).body
    }

    func sendTransaction(boc: String) async throws {
        _ = try await tosRPCCall(method: "sendBocReturnHash", params: ["boc": boc])
    }

    func sendTransactions(batch: [String]) async throws {
        for boc in batch {
            try await sendTransaction(boc: boc)
        }
    }

    func estimateFee(address: Address, boc: String) async throws -> UInt64 {
        let response = try await tosRPCCall(
            method: "estimateFee",
            params: ["address": address.toRaw(), "body": boc]
        )
        let fees = response["source_fees"] as? [String: Any] ?? response
        let total = integer(fees["in_fwd_fee"])
            + integer(fees["storage_fee"])
            + integer(fees["gas_fee"])
            + integer(fees["fwd_fee"])
        return UInt64(max(total, 0))
    }
}

// MARK: - NFTs

extension API {
    func getAccountNftItems(
        address: Address,
        collectionAddress: Address?,
        limit: Int?,
        offset: Int?,
        isIndirectOwnership: Bool
    ) async throws -> [NFT] {
        let requestedLimit = max(0, limit ?? 1_000)
        let requestedOffset = max(0, offset ?? 0)
        let response = try await tosRPCCall(
            method: "getAccountNfts",
            params: ["address": address.toRaw(), "limit": requestedLimit + requestedOffset]
        )
        guard let entries = response["nfts"] as? [[String: Any]] else {
            throw TOSRPCClient.Error.invalidResponse
        }
        var result = [NFT]()
        for entry in entries.dropFirst(requestedOffset) {
            guard result.count < requestedLimit,
                  let raw = entry["nft_item"] as? String,
                  let nft = try? await tosNFT(raw)
            else { continue }
            if let collectionAddress, nft.collection?.address != collectionAddress { continue }
            result.append(nft)
        }
        return result
    }

    func getNftItemsByAddresses(_ addresses: [Address]) async throws -> [NFT] {
        var result = [NFT]()
        for address in addresses {
            if let nft = try? await tosNFT(address.toRaw()) {
                result.append(nft)
            }
        }
        return result
    }
}

// MARK: - Jettons

extension API {
    func resolveJetton(address: Address) async throws -> JettonInfo {
        try await tosJettonInfo(address)
    }
}

// MARK: - Native TOS token mapping

private extension API {
    func tosJettonInfo(_ address: Address) async throws -> JettonInfo {
        let data = try await tosRPCCall(method: "getTokenData", params: ["address": address.toRaw()])
        guard data["@type"] as? String == "ext.tokens.jettonMasterData" else {
            throw TOSRPCClient.Error.invalidResponse
        }
        let offchain = await tosOffchainMetadata(data["jetton_metadata_uri"] as? String)
        let name = (data["jetton_name"] as? String)?.nilIfEmpty
            ?? (offchain?["name"] as? String)?.nilIfEmpty
            ?? "Jetton \(address.toRaw().suffix(6))"
        let symbol = (data["jetton_symbol"] as? String)?.nilIfEmpty
            ?? (offchain?["symbol"] as? String)?.nilIfEmpty
        let decimals = Int((data["jetton_decimals"] as? String)?.nilIfEmpty
            ?? (offchain?["decimals"] as? String)?.nilIfEmpty ?? "") ?? 9
        let image = (data["jetton_image"] as? String)?.nilIfEmpty
            ?? (offchain?["image"] as? String)?.nilIfEmpty
        return JettonInfo(
            isTransferable: true,
            hasCustomPayload: false,
            address: address,
            fractionDigits: decimals,
            name: name,
            symbol: symbol,
            verification: .none,
            imageURL: image.flatMap(URL.init(string:))
        )
    }

    func tosJettonWalletBalance(_ address: String) async throws -> BigUInt {
        let result = try await tosRPCCall(
            method: "runGetMethod",
            params: ["address": address, "method": "get_wallet_data", "stack": []]
        )
        guard integer(result["exit_code"]) == 0,
              let stack = result["stack"] as? [Any], stack.count >= 4
        else { throw TOSRPCClient.Error.invalidResponse }
        return try tosStackBigUInt(stack[stack.count - 1])
    }

    func tosNFT(_ rawAddress: String) async throws -> NFT {
        let address = try Address.parse(rawAddress)
        let data = try await tosRPCCall(method: "getTokenData", params: ["address": rawAddress])
        guard data["@type"] as? String == "ext.tokens.nftItemData" else {
            throw TOSRPCClient.Error.invalidResponse
        }
        let collectionRaw = (data["collection_address"] as? String)?.nilIfEmpty
        let collectionAddress = collectionRaw.flatMap { try? Address.parse($0) }
        let collectionData: [String: Any]? = if let collectionRaw {
            try? await tosRPCCall(method: "getTokenData", params: ["address": collectionRaw])
        } else {
            nil
        }
        let itemOffchain = await tosOffchainMetadata(data["nft_metadata_uri"] as? String)
        let collectionOffchain = await tosOffchainMetadata(collectionData?["collection_metadata_uri"] as? String)
        let image = ((data["nft_image"] as? String)?.nilIfEmpty
            ?? (itemOffchain?["image"] as? String)?.nilIfEmpty
            ?? (collectionData?["collection_image"] as? String)?.nilIfEmpty
            ?? (collectionOffchain?["image"] as? String)?.nilIfEmpty).flatMap(URL.init(string:))
        let owner = (data["owner_address"] as? String)?.nilIfEmpty.flatMap { raw in
            (try? Address.parse(raw)).map { WalletAccount(address: $0, name: nil, isScam: false, isWallet: true) }
        }
        let collection = collectionAddress.map {
            NFTCollection(
                address: $0,
                name: (collectionData?["collection_name"] as? String)?.nilIfEmpty
                    ?? (collectionOffchain?["name"] as? String)?.nilIfEmpty,
                description: (collectionData?["collection_description"] as? String)?.nilIfEmpty
                    ?? (collectionOffchain?["description"] as? String)?.nilIfEmpty
            )
        }
        let attributes: [NFT.Attribute] = (itemOffchain?["attributes"] as? [[String: Any]] ?? []).compactMap { row -> NFT.Attribute? in
            guard let key = (row["trait_type"] as? String)?.nilIfEmpty
                    ?? (row["key"] as? String)?.nilIfEmpty,
                  let rawValue = row["value"]
            else { return nil }
            let value = (rawValue as? String) ?? (rawValue as? NSNumber)?.stringValue
            return value.map { NFT.Attribute(key: key, value: $0) }
        }
        return NFT(
            address: address,
            owner: owner,
            name: (data["nft_name"] as? String)?.nilIfEmpty
                ?? (itemOffchain?["name"] as? String)?.nilIfEmpty
                ?? (collectionData?["collection_name"] as? String)?.nilIfEmpty,
            imageURL: image,
            preview: NFT.Preview(size5: image, size100: image, size500: image, size1500: image),
            description: (data["nft_description"] as? String)?.nilIfEmpty
                ?? (itemOffchain?["description"] as? String)?.nilIfEmpty
                ?? (collectionData?["collection_description"] as? String)?.nilIfEmpty,
            attributes: attributes,
            collection: collection,
            programmaticButtons: nil,
            dns: nil,
            sale: nil,
            trust: .none,
            renderType: nil,
            lottieURL: nil
        )
    }

    func tosStackBigUInt(_ entry: Any) throws -> BigUInt {
        guard let pair = entry as? [Any], pair.count == 2,
              pair[0] as? String == "num", let text = pair[1] as? String,
              let value = text.hasPrefix("0x")
                ? BigUInt(String(text.dropFirst(2)), radix: 16)
                : BigUInt(text)
        else { throw TOSRPCClient.Error.invalidResponse }
        return value
    }

    func tosOffchainMetadata(_ rawURI: String?) async -> [String: Any]? {
        guard let rawURI = rawURI?.nilIfEmpty else { return nil }
        let value: String
        if rawURI.hasPrefix("ipfs://") {
            value = "https://ipfs.io/ipfs/" + String(rawURI.dropFirst("ipfs://".count))
        } else {
            value = rawURI
        }
        guard let url = URL(string: value), url.scheme == "https" || url.scheme == "http" else { return nil }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard data.count <= 2_000_000,
                  let status = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(status)
            else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Rates

extension API {
    func getRates(currencies: [Currency], jettons: [String]) async throws -> Rates {
        let tokens = ["TON", "USDT"] + jettons
        let request = try await createRequest {
            RatesAPI.getRatesWithRequestBuilder(
                tokens: tokens,
                currencies: currencies.map { $0.code }
            )
        }

        let response = try await performRequest(request: request).body

        return parseResponse(rates: response.rates, jettons: jettons)
    }

    private func parseResponse(rates: [String: TonAPI.TokenRates], jettons: [String]) -> Rates {
        var tonRates = [Rates.Rate]()
        var usdtRates = [Rates.Rate]()
        var jettonsRates = [String: [Rates.Rate]]()

        for key in rates.keys {
            guard let rates = rates[key] else { continue }
            if key.lowercased() == TonInfo.symbol.lowercased() {
                guard let prices = rates.prices else { continue }
                let diff24h = rates.diff24h
                tonRates = prices.compactMap { price -> Rates.Rate? in
                    guard let currency = Currency(code: price.key) else { return nil }
                    let diff24h = diff24h?[price.key]
                    return Rates.Rate(currency: currency, rate: Decimal(price.value), diff24h: diff24h)
                }
                continue
            }
            if key.lowercased() == "usdt" {
                guard let prices = rates.prices else { continue }
                let diff24h = rates.diff24h
                usdtRates = prices.compactMap { price -> Rates.Rate? in
                    guard let currency = Currency(code: price.key) else { return nil }
                    let diff24h = diff24h?[price.key]
                    return Rates.Rate(currency: currency, rate: Decimal(price.value), diff24h: diff24h)
                }
                continue
            }
            guard jettons.contains(where: { $0.lowercased() == key.lowercased() }) else { continue }
            guard let prices = rates.prices else { continue }
            let diff24h = rates.diff24h
            let jettonRates: [Rates.Rate] = prices.compactMap { price -> Rates.Rate? in
                guard let currency = Currency(code: price.key) else { return nil }
                let diff24h = diff24h?[price.key]
                return Rates.Rate(currency: currency, rate: Decimal(price.value), diff24h: diff24h)
            }
            jettonsRates[key] = jettonRates
        }

        return Rates(
            ton: tonRates,
            usdt: usdtRates,
            jettonRates: jettonsRates
        )
    }
}

// MARK: - DNS

extension API {
    func resolveDomainName(_ domainName: String) async throws -> FriendlyAddress {
        let evidence = try await resolveTOSDomain(domainName)
        let address = try Address.parse(evidence.resolvedAddress)
        // DNS is an alias, not evidence that the target is a wallet. Use the
        // bounceable form so an inactive or incompatible target fails safely.
        return FriendlyAddress(address: address, bounceable: true)
    }

    func getDomainExpirationDate(_ domainName: String) async throws -> Date? {
        let evidence = try await resolveTOSDomain(domainName)
        return Date(timeIntervalSince1970: TimeInterval(evidence.renewalDeadline))
    }
}

extension API {
    enum APIError: Swift.Error {
        case incorrectResponse
        case serverError(statusCode: Int)
    }

    private struct ChartResponse: Decodable {
        let coordinates: [Coordinate]

        enum CodingKeys: String, CodingKey {
            case points
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let points = try container.decode([[Double]].self, forKey: .points)
            let coordinates = points.compactMap { item -> Coordinate? in
                guard item.count == 2 else { return nil }
                return Coordinate(x: item[0], y: item[1])
            }
            self.coordinates = coordinates
        }
    }

    func getChart(token: String, period: Period, currency: Currency) async throws -> [Coordinate] {
        guard var components = await URLComponents(string: configuration.tonapiV2Endpoint) else { return [] }
        components.path = "/v2/rates/chart"
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "currency", value: currency.code),
            URLQueryItem(name: "start_date", value: "\(Int(period.startDate.timeIntervalSince1970))"),
            URLQueryItem(name: "end_date", value: "\(Int(period.endDate.timeIntervalSince1970))"),
        ]

        guard let url = components.url else { return [] }
        let token = await configuration.tonApiV2Key
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = (response as? HTTPURLResponse) else {
            throw APIError.incorrectResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw APIError.serverError(statusCode: httpResponse.statusCode)
        }
        let chartResponse = try JSONDecoder().decode(ChartResponse.self, from: data)
        return chartResponse.coordinates.reversed()
    }
}

// MARK: - Jetton

extension API {
    func getCustomPayload(address: Address, jettonAddress: Address) async throws -> JettonTransferPayload {
        let request = try await createRequest {
            JettonsAPI.getJettonTransferPayloadWithRequestBuilder(
                accountId: address.toRaw(),
                jettonId: jettonAddress.toRaw()
            )
        }
        let response = try await performRequest(request: request).body
        return try JettonTransferPayload(customPayload: response.customPayload, stateInit: response.stateInit)
    }
}

// MARK: - Staking

extension API {
    func getPools(address: Address) async throws -> [StackingPoolInfo] {
        let request = try await createRequest {
            StakingAPI.getStakingPoolsWithRequestBuilder(
                availableFor: address.toRaw(),
                includeUnverified: false
            )
        }

        let response = try await performRequest(request: request).body
        return response.pools.compactMap {
            try? StackingPoolInfo(accountStakingInfo: $0, implementations: response.implementations)
        }
    }

    func getNominators(address: Address) async throws -> [AccountStackingInfo] {
        let request = try await createRequest {
            StakingAPI.getAccountNominatorsPoolsWithRequestBuilder(accountId: address.toRaw())
        }

        let response = try await performRequest(request: request).body
        return response.pools.compactMap { try? AccountStackingInfo(accountStakingInfo: $0) }
    }
}

// MARK: - Blockchain

extension API {
    func getWalletAddress(jettonMaster: String, owner: String) async throws -> Address {
        let request = try await createRequest {
            BlockchainAPI.execGetMethodForBlockchainAccountWithRequestBuilder(
                accountId: jettonMaster,
                methodName: "get_wallet_address",
                args: [owner]
            )
        }

        let response = try await performRequest(request: request).body

        guard let decoded = response.decoded?.value as? [String: Any],
              let jettonWalletAddress = decoded["jetton_wallet_address"] as? String
        else {
            throw APIError.incorrectResponse
        }

        return try Address.parse(jettonWalletAddress)
    }
}

// MARK: - TonConnect

extension API {
    func getTonProofToken(wallet: Wallet, tonProof: TonConnect.TonProof) async throws -> String {
        let builder = Builder()
        try wallet.stateInit.storeTo(builder: builder)
        let stateInit = try builder.endCell().toBoc().base64EncodedString()
        let signature = try tonProof.signature.signature().base64EncodedString()
        let walletAddress = try wallet.address.toRaw()

        let request = try await createRequest {
            WalletAPI.tonConnectProofWithRequestBuilder(
                tonConnectProofRequest: TonConnectProofRequest(
                    address: walletAddress,
                    proof: TonConnectProofRequestProof(
                        timestamp: Int64(tonProof.timestamp),
                        domain: TonConnectProofRequestProofDomain(
                            lengthBytes: Int(tonProof.domain.lengthBytes),
                            value: tonProof.domain.value
                        ),
                        signature: signature,
                        payload: tonProof.payload,
                        stateInit: stateInit
                    )
                )
            )
        }

        let response = try await performRequest(request: request).body
        return response.token
    }

    func getTonconnectPayload() async throws -> String {
        let request = try await createRequest {
            ConnectAPI.getTonConnectPayloadWithRequestBuilder()
        }
        let response = try await performRequest(request: request).body
        return response.payload
    }
}

// MARK: - Time

extension API {
    func getTime() async throws -> TimeInterval {
        let response = try await tosRPCCall(
            method: "getAddressInformation",
            params: ["address": "0:0000000000000000000000000000000000000000000000000000000000000000"]
        )
        let timestamp = integer(response["sync_utime"])
        return timestamp > 0 ? TimeInterval(timestamp) : Date().timeIntervalSince1970
    }
}

// MARK: - Status

extension API {
    func getStatus() async throws -> Int {
        _ = try await tosRPCCall(method: "getMasterchainInfo")
        return 0
    }
}
