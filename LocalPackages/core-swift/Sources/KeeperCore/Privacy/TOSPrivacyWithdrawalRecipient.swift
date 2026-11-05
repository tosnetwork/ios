import CoreComponents
import TonSwift

public enum TOSPrivacyWithdrawalRecipient {
    public static func parse(_ input: String, network: Network) throws -> Address {
        let address = try Address.parse(input)
        if let friendly = try? FriendlyAddress(string: input) {
            guard !friendly.isTestOnly || network == .testnet else { throw TOSPQError.invalidInput }
        }
        guard address.workchain == 0, address.hash.count == 32 else { throw TOSPQError.invalidInput }
        return address
    }
}
