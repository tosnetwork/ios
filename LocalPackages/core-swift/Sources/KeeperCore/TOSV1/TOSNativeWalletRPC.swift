import Foundation
import TonSwift

/// Bind native counters to the shipped code and canonical initial address,
/// including when a node omits this contract from its wallet-code registry.
enum TOSNativeWalletRPC {
    private static let trustedCode = Result {
        try TOSWalletV5R1(publicKey: Data(count: 32), networkGlobalId: 0).code
    }

    static func matchesSnapshot(_ snapshot: [String: Any]) throws -> Bool {
        guard let encoded = snapshot["code"] as? String else { throw TOSRPCClient.Error.invalidResponse }
        return try TOSRPCOrdinaryBOC.decode(encoded).hash() == trustedCode.get().hash()
    }

    static func normalizeSnapshot(_ snapshot: [String: Any], address: Address,
                                  expectedWallet: Wallet? = nil) throws -> [String: Any] {
        if let wallet = expectedWallet {
            guard try wallet.contractVersion == .tosV5R1, try wallet.address == address else {
                throw TOSRPCClient.Error.invalidResponse
            }
        }
        guard let state = snapshot["state"] as? String else { throw TOSRPCClient.Error.invalidResponse }
        if state == "uninitialized" || state == "uninit" {
            guard expectedWallet != nil, snapshot["code"] as? String == "", snapshot["data"] as? String == "" else {
                throw TOSRPCClient.Error.invalidResponse
            }
            var result = snapshot
            result["account_state"] = "uninitialized"; result["wallet"] = false; result["seqno"] = UInt32(0)
            return result
        }
        guard state == "active", let codeText = snapshot["code"] as? String,
              let dataText = snapshot["data"] as? String else { throw TOSRPCClient.Error.invalidResponse }
        let code = try TOSRPCOrdinaryBOC.decode(codeText)
        let known = try trustedCode.get()
        guard code.hash() == known.hash() else { throw TOSRPCClient.Error.invalidResponse }
        let slice = try TOSRPCOrdinaryBOC.decode(dataText).beginParse()
        guard try slice.loadBoolean() else { throw TOSRPCClient.Error.invalidResponse }
        let seqno = UInt32(try slice.loadUint(bits: 32))
        let subwallet = UInt32(try slice.loadUint(bits: 32))
        let key = try slice.loadBytes(32)
        _ = try slice.loadMaybeRef()
        try slice.endParse()
        let initial = try Builder().store(bit: true).store(uint: 0, bits: 32)
            .store(uint: subwallet, bits: 32).store(data: key).store(bit: false).endCell()
        let stateInit = try Builder().store(bit: false).store(bit: false)
            .storeMaybe(ref: known).storeMaybe(ref: initial).store(bit: false).endCell()
        guard stateInit.hash() == address.hash else { throw TOSRPCClient.Error.invalidResponse }
        var result = snapshot
        result["account_state"] = "active"; result["wallet"] = true
        result["seqno"] = seqno; result["wallet_type"] = WalletContractVersion.tosV5R1.rawValue
        return result
    }
}
