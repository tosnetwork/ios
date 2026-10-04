import Foundation
import TonSwift

/// The current TOS node does not classify the ordinary contracts shipped by the
/// previous App. Read their counter from one code/data snapshot, never from a
/// permissive getter or a null counter. These hashes pin the original TonSwift
/// 991959e784ce55b65f5a6f66647d149af6eaf362 contracts; Beta library code is excluded.
enum TOSLegacyWalletRPC {
    private static let profiles: [(WalletContractVersion, String)] = [
        (.v3R1, "b61041a58a7980b946e8fb9e198e3c904d24799ffa36574ea4251c41a566f581"),
        (.v3R2, "84dafa449f98a6987789ba232358072bc0f76dc4524002a5d0918b9a75d2d599"),
        (.v4R1, "64dd54805522c5be8a9db59cea0105ccf0d08786ca79beb8cb79e880a8d7322d"),
        (.v4R2, "feb5ff6820e2ff0d9483e7e0d62c817d846789fb4ae580c878866d959dabd5c0"),
        (.v5R1, "20834b7b72b112147e1b2fb457b84e74d1a30f04f737d4f62a668e9552d2b72f"),
    ]

    static func supports(_ version: WalletContractVersion) -> Bool {
        profiles.contains { $0.0 == version }
    }

    static func normalizeSnapshot(
        _ snapshot: [String: Any], address: Address, expectedWallet: Wallet? = nil
    ) throws -> [String: Any] {
        if let wallet = expectedWallet {
            guard supports(try wallet.contractVersion), try wallet.address == address else {
                throw TOSRPCClient.Error.invalidResponse
            }
        }
        guard let state = snapshot["state"] as? String else { throw TOSRPCClient.Error.invalidResponse }
        if state == "uninitialized" || state == "uninit" {
            // Only stored, known legacy metadata can identify a deployment.
            // Address-only fallback began with an active unclassified account;
            // a later empty snapshot cannot supply its identity or counter.
            guard expectedWallet != nil,
                  snapshot["code"] as? String == "", snapshot["data"] as? String == "" else {
                throw TOSRPCClient.Error.invalidResponse
            }
            var result = snapshot
            result["account_state"] = "uninitialized"
            result["wallet"] = false
            result["seqno"] = UInt32(0)
            return result
        }
        guard state == "active" else { throw TOSRPCClient.Error.invalidResponse }
        let code = try ordinaryCell(snapshot["code"])
        let hash = code.hash().map { String(format: "%02x", $0) }.joined()
        guard let version = profiles.first(where: { $0.1 == hash })?.0 else {
            throw TOSRPCClient.Error.invalidResponse
        }
        let data = try ordinaryCell(snapshot["data"])
        let slice = try data.beginParse()
        if version == .v5R1 {
            guard try slice.loadBoolean() else { throw TOSRPCClient.Error.invalidResponse }
        }
        let seqno = UInt32(try slice.loadUint(bits: 32))
        let walletID = UInt32(try slice.loadUint(bits: 32))
        let publicKey = try slice.loadBytes(32)
        if version == .v4R1 || version == .v4R2 || version == .v5R1 {
            // HashmapE has exactly a presence bit and, when present, one ref.
            // Its contents may change after deployment; signed Ed25519 sends
            // still require the immutable public key and wallet ID below.
            _ = try slice.loadMaybeRef()
        }
        try slice.endParse()

        let initialData = Builder()
        if version == .v5R1 { try initialData.store(bit: true) }
        try initialData.store(uint: 0, bits: 32).store(uint: walletID, bits: 32).store(data: publicKey)
        if version != .v3R1 && version != .v3R2 { try initialData.store(bit: false) }
        let initialCell = try initialData.endCell()
        let initialState = try Builder()
            .store(bit: false).store(bit: false)
            .storeMaybe(ref: code).storeMaybe(ref: initialCell).store(bit: false).endCell()
        guard initialState.hash() == address.hash else { throw TOSRPCClient.Error.invalidResponse }

        if let wallet = expectedWallet {
            let expected = try initialComponents(wallet: wallet)
            guard try wallet.contractVersion == version,
                  try wallet.publicKey.data == publicKey,
                  expected.code.hash() == code.hash(), expected.data.hash() == initialCell.hash()
            else { throw TOSRPCClient.Error.invalidResponse }
        }
        var result = snapshot
        result["account_state"] = "active"
        result["wallet"] = true
        result["seqno"] = seqno
        result["wallet_type"] = version.rawValue
        return result
    }

    static func needsFallback(_ information: [String: Any]) -> Bool {
        information["account_state"] as? String == "active"
            && information["wallet"] as? Bool == false
            && information["seqno"] is NSNull
    }

    static func initialComponents(wallet: Wallet) throws -> (code: Cell, data: Cell) {
        let slice = try Builder().store(wallet.stateInit).endCell().beginParse()
        if try slice.loadBoolean() { try slice.skip(5) }
        if try slice.loadBoolean() { try slice.skip(2) }
        guard let code = try slice.loadMaybeRef(), let data = try slice.loadMaybeRef() else {
            throw TOSRPCClient.Error.invalidResponse
        }
        return (code, data)
    }

    private static func ordinaryCell(_ value: Any?) throws -> Cell {
        guard let encoded = value as? String else { throw TOSRPCClient.Error.invalidResponse }
        return try TOSRPCOrdinaryBOC.decode(encoded)
    }
}

extension TOSRPCClient {
    /// This entrypoint also fixes address-only seqno/revision discovery. The
    /// second response must independently bind the canonical initial address;
    /// no state or counter from the first response is combined with its data.
    func walletInformation(address: Address) async throws -> [String: Any] {
        let endpoint = await basePath()
        let client = TOSRPCClient(basePath: { endpoint }, urlSession: urlSession)
        let information = try await client.call(method: "getWalletInformation", params: ["address": address.toRaw()])
        guard TOSLegacyWalletRPC.needsFallback(information) else { return information }
        let snapshot = try await client.call(method: "getAddressInformation", params: ["address": address.toRaw()])
        return try TOSLegacyWalletRPC.normalizeSnapshot(snapshot, address: address)
    }

    func walletInformation(wallet: Wallet) async throws -> [String: Any] {
        let endpoint = await basePath()
        let client = TOSRPCClient(basePath: { endpoint }, urlSession: urlSession)
        try await client.verifyNetworkIdentity(wallet: wallet)
        return try await client.verifiedWalletInformation(wallet: wallet)
    }

    /// Call only on an endpoint captured and verified for this operation.
    func verifiedWalletInformation(wallet: Wallet) async throws -> [String: Any] {
        let address = try wallet.address
        if TOSLegacyWalletRPC.supports(try wallet.contractVersion) {
            let snapshot = try await call(method: "getAddressInformation", params: ["address": address.toRaw()])
            return try TOSLegacyWalletRPC.normalizeSnapshot(snapshot, address: address, expectedWallet: wallet)
        }
        return try await call(method: "getWalletInformation", params: ["address": address.toRaw()])
    }
}
