import Foundation
import TonSwift
import CoreComponents

public struct TOSPQNodeCapabilities {
    public let network: Int32
    public let version: UInt32
}
public struct TOSPQAccountSummary {
    public let balance: UInt64
    public let state: String
}
public struct TOSPQHistoryItem {
    public let hash: String
    public let timestamp: UInt32
    public let successful: Bool
}
public struct TOSPQFeeSnapshot {
    public let seqno: UInt32
    public let chainTime: UInt32
    public let balance: UInt64
}
extension API {
    public func pqSession() async -> TOSPQNodeSession { TOSPQNodeSession(node: await boundTOSRPCClient()) }
}
/// One operator-selected endpoint, pinned for the entire operation/review session.
public struct TOSPQNodeSession {
    let node: TOSRPCClient

    public func pqSnapshot(wallet: TOSPQWallet) async throws -> TOSPQSnapshot { try await node.pqSnapshot(wallet: wallet) }
    public func pqCapabilities() async throws -> TOSPQNodeCapabilities {
        let head = try await node.call(method: "getMasterchainInfo")
        guard let last = head["last"] as? [String: Any], let number = last["seqno"] as? NSNumber, let n = TOSWalletRPC.unsignedInteger(number), n <= UInt32.max else { throw TOSPQError.invalidInput }
        return try await TOSPQNodeCapabilities(
            network: TOSNetworkIdentity.decodeConfiguration(node.call(method: "getConfigParam", params: ["param": 19, "seqno": n])),
            version: TOSNetworkIdentity.decodeVMVersion(node.call(method: "getConfigParam", params: ["param": 8, "seqno": n])))
    }
    public func pqAccount(address: Address) async throws -> TOSPQAccountSummary {
        let account = try await node.call(method: "getAddressInformation", params: ["address": address.toRaw()])
        guard let raw = account["balance"] as? String, let balance = UInt64(raw), let state = account["state"] as? String else { throw TOSPQError.invalidInput }
        return TOSPQAccountSummary(balance: balance, state: state)
    }
    public func pqHistory(address: Address) async throws -> [TOSPQHistoryItem] {
        return try await node.callTransactions(address: address).map { tx in
            guard let identity = tx["transaction_id"] as? [String: Any], let hash = identity["hash"] as? String,
                  let number = tx["utime"] as? NSNumber, let time = TOSWalletRPC.unsignedInteger(number), time <= UInt32.max else { throw TOSPQError.invalidInput }
            let compute = tx["compute"] as? [String: Any]
            let action = tx["action"] as? [String: Any]
            let successful = tx["aborted"] as? Bool == false && compute?["success"] as? Bool == true &&
                (compute?["exit_code"] as? NSNumber)?.intValue == 0 && (action == nil || action?["success"] as? Bool == true)
            return TOSPQHistoryItem(hash: hash, timestamp: UInt32(time), successful: successful)
        }
    }
    public func pqFeeSnapshot(payer: Wallet, expectedNetwork: Int32) async throws -> TOSPQFeeSnapshot {
        guard try payer.contractVersion == .tosV5R1, payer.identity.networkGlobalId == expectedNetwork else { throw TOSPQError.keyBinding }
        let account = try await node.call(method: "getAddressInformation", params: ["address": payer.address.toRaw()])
        guard let contract = try payer.contract as? TOSWalletV5R1 else { throw TOSPQError.keyBinding }
        guard let balanceString = account["balance"] as? String, let balance = UInt64(balanceString),
              let number = account["sync_utime"] as? NSNumber, let time = TOSWalletRPC.unsignedInteger(number), time > 0, time <= UInt32.max else { throw TOSPQError.invalidInput }
        if account["state"] as? String == "uninitialized" || account["state"] as? String == "uninit" {
            return TOSPQFeeSnapshot(seqno: 0, chainTime: UInt32(time), balance: balance)
        }
        guard account["state"] as? String == "active", let code = account["code"] as? String,
              try TOSRPCOrdinaryBOC.decode(code).hash() == contract.code.hash(), let raw = account["data"] as? String else { throw TOSPQError.keyBinding }
        let data = try TOSRPCOrdinaryBOC.decode(raw).beginParse()
        guard try data.loadBoolean() else { throw TOSPQError.keyBinding }
        let seqno = try data.loadUint(bits: 32)
        guard try data.loadUint(bits: 32) == 0, try data.loadBytes(32) == payer.publicKey.data,
              try !data.loadBoolean(), data.remainingBits == 0, data.remainingRefs == 0 else { throw TOSPQError.keyBinding }
        return TOSPQFeeSnapshot(seqno: UInt32(seqno), chainTime: UInt32(time), balance: balance)
    }
    public func pqEstimateFee(payer: Wallet, unsigned: Cell, snapshot: TOSPQFeeSnapshot) async throws -> UInt64 {
        let body = try Builder().store(slice: unsigned.beginParse()).store(data: Data(repeating: 0, count: 64)).endCell()
        var params: [String: Any] = ["address": try payer.address.toRaw(), "body": try body.toBoc().base64EncodedString(), "ignore_chksig": true]
        if snapshot.seqno == 0 {
            let (code, data) = try TOSLegacyWalletRPC.initialComponents(wallet: payer)
            params["init_code"] = try code.toBoc().base64EncodedString()
            params["init_data"] = try data.toBoc().base64EncodedString()
        }
        return try TOSWalletRPC.decodeFees(await node.call(method: "estimateFee", params: params))
    }
    public func pqBroadcast(boc: String, expectedNetwork: Int32, minimumVM: Int) async throws {
        let head = try await node.call(method: "getMasterchainInfo")
        guard let last = head["last"] as? [String: Any], let number = last["seqno"] as? NSNumber, let n = TOSWalletRPC.unsignedInteger(number), n <= UInt32.max,
            try await TOSNetworkIdentity.decodeConfiguration(node.call(method: "getConfigParam", params: ["param": 19, "seqno": n])) == expectedNetwork,
            try await TOSNetworkIdentity.decodeVMVersion(node.call(method: "getConfigParam", params: ["param": 8, "seqno": n])) >= UInt32(minimumVM) else { throw TOSPQError.keyBinding }
        _ = try await node.call(method: "sendBocReturnHash", params: ["boc": boc])
    }
}
