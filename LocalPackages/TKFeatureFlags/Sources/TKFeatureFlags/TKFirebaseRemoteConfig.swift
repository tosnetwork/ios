import Foundation

// TOS does not use Firebase Remote Config. This is a no-op RemoteConfigProvider
// kept under the original type name so the app's launch wiring compiles.
// Feature flags fall back to their built-in defaults (subscript returns nil).
public final class TKFirebaseRemoteConfigProvider {
    // requestTimeoutMs is accepted for call-site compatibility but unused: there
    // is no remote config to fetch.
    public init(requestTimeoutMs: UInt64) {}
}

extension TKFirebaseRemoteConfigProvider: RemoteConfigProvider {
    public func load() async {}

    public subscript(_ flag: String) -> Bool? {
        nil
    }
}
