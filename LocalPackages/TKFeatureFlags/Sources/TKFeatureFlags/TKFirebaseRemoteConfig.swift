import Foundation

/// Offline feature configuration used by TOS Wallet.
/// Feature flags fall back to their built-in values and never contact a remote
/// configuration or analytics service.
public final class LocalRemoteConfigProvider {
    public init() {}
}

extension LocalRemoteConfigProvider: RemoteConfigProvider {
    public func load() async {}

    public subscript(_ flag: String) -> Bool? {
        nil
    }
}
