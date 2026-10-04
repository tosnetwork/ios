import Foundation
import CoreFoundation
import TonSwift

public enum TOSNetworkIdentityError: Swift.Error, LocalizedError {
    case missingIdentity
    case invalidConfiguration
    case wrongNetwork(expected: Int32, actual: Int32)
    case unsupportedSigner
    case unsupportedVMVersion(actual: UInt32)

    public var errorDescription: String? {
        switch self {
        case .missingIdentity:
            return "This wallet has no verified TOS network identity. Import it from a reachable TOS node before sending."
        case .invalidConfiguration:
            return "The TOS node did not provide a valid network identity."
        case let .wrongNetwork(expected, actual):
            return "This wallet belongs to TOS network \(expected), but the selected node uses network \(actual)."
        case .unsupportedSigner:
            return "This signer does not support the TOS wallet signing format."
        case let .unsupportedVMVersion(actual):
            return "This TOS node uses VM version \(actual). TOS wallets require version 6 or newer."
        }
    }
}

enum TOSNetworkIdentity {
    static let minimumWalletVMVersion: UInt32 = 6

    static func decodeConfiguration(_ result: [String: Any]) throws -> Int32 {
        guard let configuration = result["config"] as? [String: Any],
              let encoded = configuration["bytes"] as? String,
              let cell = try? TOSRPCOrdinaryBOC.decode(encoded),
              cell.bits.length == 32, cell.refs.isEmpty
        else { throw TOSNetworkIdentityError.invalidConfiguration }
        return Int32(try cell.beginParse().loadInt(bits: 32))
    }

    static func decodeVMVersion(_ result: [String: Any]) throws -> UInt32 {
        guard let configuration = result["config"] as? [String: Any],
              let encoded = configuration["bytes"] as? String,
              let cell = try? TOSRPCOrdinaryBOC.decode(encoded),
              cell.bits.length == 104, cell.refs.isEmpty
        else { throw TOSNetworkIdentityError.invalidConfiguration }
        let slice = try cell.beginParse()
        guard try slice.loadUint(bits: 8) == 0xc4 else {
            throw TOSNetworkIdentityError.invalidConfiguration
        }
        return UInt32(try slice.loadUint(bits: 32))
    }

    static func requireWalletVMVersion(_ version: UInt32) throws {
        guard version >= minimumWalletVMVersion else {
            throw TOSNetworkIdentityError.unsupportedVMVersion(actual: version)
        }
    }
}

extension TOSRPCClient {
    func callForWallet(method: String, params: [String: Any], wallet: Wallet) async throws -> [String: Any] {
        // Capture the endpoint once for this entire operation, including retries.
        let endpoint = await basePath()
        let client = TOSRPCClient(basePath: { endpoint }, urlSession: urlSession)
        try await client.verifyNetworkIdentity(wallet: wallet)
        return try await client.call(method: method, params: params)
    }

    func getNetworkGlobalId() async throws -> Int32 {
        try TOSNetworkIdentity.decodeConfiguration(
            await call(method: "getConfigParam", params: ["param": 19])
        )
    }

    func requireWalletVMVersion() async throws {
        let version = try TOSNetworkIdentity.decodeVMVersion(
            await call(method: "getConfigParam", params: ["param": 8])
        )
        try TOSNetworkIdentity.requireWalletVMVersion(version)
    }

    func getVerifiedNetworkGlobalId() async throws -> Int32 {
        let identity = try await getNetworkGlobalId()
        try await requireWalletVMVersion()
        return identity
    }

    func estimateWalletFee(body: String, wallet: Wallet) async throws -> UInt64 {
        let endpoint = await basePath()
        let client = TOSRPCClient(basePath: { endpoint }, urlSession: urlSession)
        try await client.verifyNetworkIdentity(wallet: wallet)
        let account = try await client.verifiedWalletInformation(wallet: wallet)
        // Validate active account responses before treating anything as a deployment.
        _ = try TOSWalletRPC.decodeSeqno(account)
        var params: [String: Any] = ["address": try wallet.address.toRaw(), "body": body, "ignore_chksig": true]
        if TOSWalletRPC.isUninitialized(account) {
            let (code, data) = try TOSLegacyWalletRPC.initialComponents(wallet: wallet)
            params["init_code"] = try code.toBoc().base64EncodedString()
            params["init_data"] = try data.toBoc().base64EncodedString()
        }
        return try TOSWalletRPC.decodeFees(await client.call(method: "estimateFee", params: params))
    }

    func verifyNetworkIdentity(wallet: Wallet) async throws {
        guard try wallet.contractVersion == .tosV5R1 else { return }
        guard let expected = wallet.identity.networkGlobalId else {
            throw TOSNetworkIdentityError.missingIdentity
        }
        let actual = try await getNetworkGlobalId()
        guard actual == expected else {
            throw TOSNetworkIdentityError.wrongNetwork(expected: expected, actual: actual)
        }
        try await requireWalletVMVersion()
    }
}

extension API {
    func getNetworkGlobalId() async throws -> Int32 {
        try await boundTOSRPCClient().getVerifiedNetworkGlobalId()
    }
}

enum TOSWalletRPC {
    static func isUninitialized(_ response: [String: Any]) -> Bool {
        response["account_state"] as? String == "uninitialized" || response["account_state"] as? String == "uninit"
    }

    static func decodeSeqno(_ response: [String: Any]) throws -> UInt32 {
        if isUninitialized(response) {
            return 0
        }
        guard response["wallet"] as? Bool == true || response["is_wallet"] as? Bool == true else {
            throw TOSRPCClient.Error.invalidResponse
        }
        if let number = response["seqno"] as? NSNumber,
           let value = unsignedInteger(number), value <= UInt32.max {
            return UInt32(value)
        }
        if let string = response["seqno"] as? String, let value = UInt32(string) {
            return value
        }
        throw TOSRPCClient.Error.invalidResponse
    }

    static func decodeFees(_ response: [String: Any]) throws -> UInt64 {
        guard let fees = response["source_fees"] as? [String: Any] else { throw TOSRPCClient.Error.invalidResponse }
        var total: UInt64 = 0
        for key in ["in_fwd_fee", "storage_fee", "gas_fee", "fwd_fee"] {
            let value: UInt64?
            if let string = fees[key] as? String { value = UInt64(string) }
            else if let number = fees[key] as? NSNumber { value = unsignedInteger(number) }
            else { value = nil }
            guard let value else { throw TOSRPCClient.Error.invalidResponse }
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { throw TOSRPCClient.Error.invalidResponse }
            total = sum
        }
        return total
    }

    static func unsignedInteger(_ number: NSNumber) -> UInt64? {
        guard CFGetTypeID(number) != CFBooleanGetTypeID(), !(number is NSDecimalNumber) else { return nil }
        // Floating JSON values can round into integers before comparison, even
        // when the original token had a fractional part. Require integer storage.
        switch String(cString: number.objCType) {
        case "c", "s", "i", "l", "q":
            guard number.int64Value >= 0 else { return nil }
            return number.uint64Value
        case "C", "S", "I", "L", "Q":
            return number.uint64Value
        default:
            return nil
        }
    }
}
