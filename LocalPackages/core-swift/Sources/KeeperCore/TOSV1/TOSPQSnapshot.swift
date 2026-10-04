import Foundation
import TonSwift
import CoreComponents

/// The operator-selected RPC node is the trust anchor; all reads use one endpoint and height.
public struct TOSPQSnapshot {
    public let height: UInt32
    public let epoch: UInt64
    public let nonce: UInt64
    public let balance: UInt64
    public let chainTime: UInt32
}
extension API {
    public func pqSnapshot(wallet: TOSPQWallet) async throws -> TOSPQSnapshot {
        let node = await boundTOSRPCClient()
        return try await node.pqSnapshot(wallet: wallet)
    }
}
extension TOSRPCClient {
    func pqSnapshot(wallet: TOSPQWallet) async throws -> TOSPQSnapshot {
        let head = try await call(method: "getMasterchainInfo")
        guard let last = head["last"] as? [String: Any], let number = last["seqno"] as? NSNumber,
              let height = TOSWalletRPC.unsignedInteger(number), height <= UInt32.max else { throw Error.invalidResponse }
        let n = UInt32(height)
        let network = try TOSNetworkIdentity.decodeConfiguration(await call(method: "getConfigParam", params: ["param": 19, "seqno": n]))
        let version = try TOSNetworkIdentity.decodeVMVersion(await call(method: "getConfigParam", params: ["param": 8, "seqno": n]))
        guard network == wallet.network, version >= UInt32(wallet.algorithm.minimumVM) else { throw TOSPQError.invalidInput }
        let root = try await call(method: "getAddressInformation", params: ["address": wallet.moduleAddress.toRaw(), "seqno": n])
        let account = try await call(method: "getAddressInformation", params: ["address": wallet.address.toRaw(), "seqno": n])
        func cell(_ obj: [String: Any], _ key: String) throws -> Cell {
            guard let value = obj[key] as? String else { throw Error.invalidResponse }
            return try TOSRPCOrdinaryBOC.decode(value)
        }
        guard root["state"] as? String == "active", account["state"] as? String == "active",
              try cell(root, "code").hash() == wallet.moduleCode.hash(),
              (try cell(root, "data")).hash() == wallet.moduleData.hash() else { throw TOSPQError.keyBinding }
        let counters = try wallet.authCounters(code: cell(account, "code"), data: cell(account, "data"))
        guard let rawBalance = account["balance"] as? String, let balance = UInt64(rawBalance),
              let number = account["sync_utime"] as? NSNumber, let now = TOSWalletRPC.unsignedInteger(number), now > 0,
              now <= UInt32.max else { throw Error.invalidResponse }
        return TOSPQSnapshot(height: n, epoch: counters.epoch, nonce: counters.nonce, balance: balance, chainTime: UInt32(now))
    }
}
