import TonSwift

public enum TOSV1MnemonicValidator {
    public static func normalize(_ phrase: String) -> [String] {
        phrase
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    }

    public static func normalize(_ words: [String]) -> [String] {
        normalize(words.joined(separator: " "))
    }

    public static func isValid(_ words: [String]) -> Bool {
        let normalized = normalize(words)
        return normalized.count == 24 && Mnemonic.mnemonicValidate(mnemonicArray: normalized)
    }
}

public enum TOSV1DeeplinkPolicy {
    public static func allows(_ deeplink: Deeplink) -> Bool {
        switch deeplink {
        case let .transfer(.sendTransfer(data)):
            return data.jettonAddress == nil
        case .receive, .backup:
            return true
        case .transfer(.signRawTransfer),
             .buyTon,
             .staking,
             .pool,
             .exchange,
             .swap,
             .action,
             .publish,
             .externalSign,
             .tonconnect,
             .dapp,
             .battery,
             .browser,
             .story:
            return false
        }
    }
}
