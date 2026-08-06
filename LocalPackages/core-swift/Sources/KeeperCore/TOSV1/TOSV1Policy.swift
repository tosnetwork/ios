import TonSwift

public enum TOSV1MnemonicValidator {
    public static func isValid(_ words: [String]) -> Bool {
        words.count == 24 && Mnemonic.mnemonicValidate(mnemonicArray: words)
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
