import BigInt
import Foundation
import TonSwift

public final class LinkDNSController {
    public enum Error: Swift.Error {
        case failedToSign
        case indexerOffline
    }

    private let wallet: Wallet
    private let nft: NFT
    private let sendService: SendService
    private let dnsService: DNSService

    init(
        wallet: Wallet,
        nft: NFT,
        sendService: SendService,
        dnsService: DNSService
    ) {
        self.wallet = wallet
        self.nft = nft
        self.sendService = sendService
        self.dnsService = dnsService
    }

    public func emulate(dnsLink: DNSLink) async throws -> SendTransactionModel {
        let signedTransactions = try await createSignedTransactions(dnsLink: dnsLink) { transferData in
            let walletTransfer = try await UnsignedTransferBuilder(transferData: transferData)
                .createUnsignedWalletTransfer(
                    wallet: wallet
                )
            let signed = try TransferSigner.signWalletTransfer(
                walletTransfer,
                wallet: wallet,
                seqno: transferData.seqno,
                signer: WalletTransferEmptyKeySigner()
            )

            return try [signed.toBoc().hexString()]
        }

        let boc = signedTransactions[0]

        let transactionInfo = try await sendService.loadTransactionInfo(
            boc: boc,
            wallet: wallet,
            params: nil,
            currency: nil
        )

        return try SendTransactionModel(
            accountEvent: transactionInfo.event,
            risk: transactionInfo.risk,
            transaction: transactionInfo.trace.transaction
        )
    }

    public func sendLinkTransaction(
        dnsLink: DNSLink,
        signClosure: (TransferData) async throws -> SignedTransactions
    ) async throws {
        let indexingLatency = try await sendService.getIndexingLatency(wallet: wallet)
        if indexingLatency > (TonSwift.DEFAULT_TTL - 30) {
            throw Error.indexerOffline
        }

        let signedTransactions = try await createSignedTransactions(dnsLink: dnsLink) { transferData in
            try await signClosure(transferData)
        }

        if signedTransactions.isEmpty {
            throw Error.failedToSign
        }

        do {
            if signedTransactions.count == 1 {
                try await sendService.sendTransaction(boc: signedTransactions[0], wallet: wallet)
            } else {
                try await sendService.sendTransactions(batch: signedTransactions, wallet: wallet)
            }
            NotificationCenter.default.postTransactionSendNotification(wallet: wallet)
        } catch {
            throw error
        }
    }
}

private extension LinkDNSController {
    func createSignedTransactions(dnsLink: DNSLink, signClosure: (TransferData) async throws -> SignedTransactions) async throws -> SignedTransactions {
        let seqno = try await sendService.loadSeqno(wallet: wallet)
        let timeout = await sendService.getTimeoutSafely(wallet: wallet, TTL: DEFAULT_TTL)
        let linkAddress: Address?
        switch dnsLink {
        case let .link(address):
            linkAddress = address.address
        case .unlink:
            linkAddress = nil
        }

        guard let domainName = nft.dns else { throw TOSDNSManagementError.actionNotAllowed }
        let state = try await dnsService.inspectDomain(domainName, network: wallet.network)
        guard state.itemAddress == nft.address else { throw TOSDNSManagementError.actionNotAllowed }
        let value: Cell?
        if let linkAddress {
            value = try Builder()
                .store(uint: 0x9fd3, bits: 16)
                .store(linkAddress)
                .store(uint: 0, bits: 8)
                .endCell()
        } else {
            value = nil
        }
        let walletCategory = BigUInt(
            "e8d44050873dba865aa7c170ab4cce64d90839a34dcfd6cf71d14e0205443b1b",
            radix: 16
        ) ?? 0
        let operation = try TOSDNSManagementPlanner.operation(
            state: state,
            walletAddress: wallet.address,
            action: .changeRecord(category: walletCategory, value: value),
            now: UInt64(Date().timeIntervalSince1970),
            queryId: UInt64(UnsignedTransferBuilder.newWalletQueryId())
        )

        let transferData = TransferData(
            transfer: .domainOperation(operation),
            wallet: wallet,
            messageType: .ext,
            seqno: seqno,
            timeout: timeout
        )

        return try await signClosure(transferData)
    }
}

public enum OP_AMOUNT {
    public static var CHANGE_DNS_RECORD = TOSDNSAuctionRules.contractActionValue
}
