import Foundation

extension UserDefaults {
    static var tkFeatureFlagsDefaults: UserDefaults {
        UserDefaults(
            // Persistent compatibility key. Renaming it would discard existing
            // QA and developer feature-flag overrides on upgrade.
            suiteName: "featureFlags.tkFeatureFlags.tonkeeper"
        ) ?? .standard
    }
}
