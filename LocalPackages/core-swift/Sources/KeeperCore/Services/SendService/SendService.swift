import Foundation
import TonAPI
import TonSwift

public protocol SendService {
    func loadSeqno(wallet: Wallet) async throws -> UInt64
    func loadTransactionInfo(
        boc: String,
        wallet: Wallet,
        params: [EmulateMessageToWalletRequestParamsInner]?,
        currency: Currency?
    ) async throws -> TonAPI.MessageConsequences
    func sendTransaction(boc: String, wallet: Wallet) async throws
    func sendTransactions(batch: [String], wallet: Wallet) async throws
    func estimateFee(boc: String, wallet: Wallet) async throws -> UInt64
    func getTimeoutSafely(wallet: Wallet, TTL: UInt64) async -> UInt64
    func getJettonCustomPayload(wallet: Wallet, jetton: Address) async throws -> JettonTransferPayload
    func getIndexingLatency(wallet: Wallet) async throws -> Int
}

public extension SendService {
    func getTimeoutSafely(wallet: Wallet, TTL: UInt64 = TonSwift.DEFAULT_TTL) async -> UInt64 {
        await self.getTimeoutSafely(wallet: wallet, TTL: TTL)
    }

    func loadTransactionInfo(
        boc: String,
        wallet: Wallet,
        params: [EmulateMessageToWalletRequestParamsInner]? = nil,
        currency: Currency? = nil
    ) async throws -> TonAPI.MessageConsequences {
        try await self.loadTransactionInfo(boc: boc, wallet: wallet, params: params, currency: currency)
    }
}

final class SendServiceImplementation: SendService {
    private let apiProvider: APIProvider

    init(apiProvider: APIProvider) {
        self.apiProvider = apiProvider
    }

    func loadSeqno(wallet: Wallet) async throws -> UInt64 {
        let client = await apiProvider.api(wallet.network).boundTOSRPCClient()
        return UInt64(try TOSWalletRPC.decodeSeqno(await client.callForWallet(method: "getWalletInformation", params: ["address": wallet.address.toRaw()], wallet: wallet)))
    }

    func loadTransactionInfo(
        boc: String,
        wallet: Wallet,
        params: [EmulateMessageToWalletRequestParamsInner]?,
        currency: Currency?
    ) async throws -> TonAPI.MessageConsequences {
        try await apiProvider
            .api(wallet.network)
            .emulateMessageWallet(boc: boc, params: params, currency: currency?.code)
    }

    func sendTransaction(boc: String, wallet: Wallet) async throws {
        let client = await apiProvider.api(wallet.network).boundTOSRPCClient()
        _ = try await client.callForWallet(method: "sendBocReturnHash", params: ["boc": boc], wallet: wallet)
    }

    func sendTransactions(batch: [String], wallet: Wallet) async throws {
        let client = await apiProvider.api(wallet.network).boundTOSRPCClient()
        for boc in batch {
            _ = try await client.callForWallet(method: "sendBocReturnHash", params: ["boc": boc], wallet: wallet)
        }
    }

    func estimateFee(boc: String, wallet: Wallet) async throws -> UInt64 {
        let client = await apiProvider.api(wallet.network).boundTOSRPCClient()
        return try await client.estimateWalletFee(body: boc, wallet: wallet)
    }

    func getIndexingLatency(wallet: Wallet) async throws -> Int {
        try await apiProvider.api(wallet.network)
            .getStatus()
    }

    func getTimeoutSafely(wallet: Wallet, TTL: UInt64) async -> UInt64 {
        do {
            return try await UInt64(
                apiProvider.api(wallet.network)
                    .getTime()
            ) + TTL
        } catch {
            return UInt64(Date().timeIntervalSince1970) + TTL
        }
    }

    func getJettonCustomPayload(wallet: Wallet, jetton: Address) async throws -> JettonTransferPayload {
        try await apiProvider.api(wallet.network).getCustomPayload(address: wallet.address, jettonAddress: jetton)
    }
}
