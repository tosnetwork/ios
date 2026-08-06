import Foundation
import TonSwift

enum TOSAccountHistoryMapper {
    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    static func events(_ value: Any?, account: Address) throws -> [AccountEvent] {
        guard let values = value as? [[String: Any]] else {
            throw TOSRPCClient.Error.invalidResponse
        }
        return try values.map { try event($0, account: account) }
    }

    static func event(_ value: [String: Any], account: Address) throws -> AccountEvent {
        guard let eventId = value["event_id"] as? String,
              let timestamp = int64(value["timestamp"]),
              let transfers = value["transfers"] as? [[String: Any]] else {
            throw TOSRPCClient.Error.invalidResponse
        }
        let fee = int64(value["fee"]).flatMap { UInt64(exactly: $0) } ?? 0
        return AccountEvent(
            eventId: eventId,
            date: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            account: walletAccount(account),
            isScam: false,
            isInProgress: false,
            extra: .Fee(fee),
            excess: nil,
            progress: nil,
            actions: try transfers.map { try action($0, subject: account) }
        )
    }

    private static func action(_ value: [String: Any], subject: Address) throws -> AccountEventAction {
        guard let direction = value["direction"] as? String,
              direction == "incoming" || direction == "outgoing",
              let sourceString = value["source"] as? String,
              let destinationString = value["destination"] as? String,
              let amount = int64(value["amount"]),
              amount >= 0 else {
            throw TOSRPCClient.Error.invalidResponse
        }
        let source = try Address.parse(sourceString)
        let destination = try Address.parse(destinationString)
        let bounced = value["bounced"] as? Bool ?? false
        let counterparty = direction == "incoming" ? source : destination
        let transfer = AccountEventAction.TonTransfer(
            sender: walletAccount(source),
            recipient: walletAccount(destination),
            amount: amount,
            comment: value["comment"] as? String,
            encryptedComment: nil
        )
        let preview = AccountEventAction.SimplePreview(
            name: direction == "incoming" ? "Received TOS" : "Sent TOS",
            description: counterparty.toString(bounceable: true),
            image: nil,
            value: String(amount),
            valueImage: nil,
            accounts: [walletAccount(counterparty)]
        )
        return AccountEventAction(type: .tonTransfer(transfer), status: bounced ? .failed : .ok, preview: preview)
    }

    private static func walletAccount(_ address: Address) -> WalletAccount {
        WalletAccount(address: address, name: nil, isScam: false, isWallet: true)
    }
}
