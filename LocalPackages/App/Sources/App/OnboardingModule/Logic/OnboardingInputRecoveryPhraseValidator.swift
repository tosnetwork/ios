import CoreComponents
import Foundation
import KeeperCore
import TKScreenKit
import TonSwift

struct OnboardingInputRecoveryPhraseValidator: TKInputRecoveryPhraseValidator {
    func validateWord(_ word: String) -> Bool {
        Mnemonic.words.contains(word)
    }

    func validatePhrase(_ phrase: [String]) -> RecoveryPhraseValidationResult {
        if TOSV1MnemonicValidator.isValid(phrase) {
            return .ton
        }
        return .invalid
    }
}
