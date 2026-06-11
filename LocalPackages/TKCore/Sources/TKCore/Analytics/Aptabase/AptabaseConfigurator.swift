import Foundation

// TOS ships no analytics/telemetry. These are no-op shells kept so existing
// call sites compile; the Aptabase SDK has been removed.
public final class AptabaseConfigurator {
    public static let configurator = AptabaseConfigurator()

    private init() {}

    public func configure(sendStatsImmediately: Bool?) {}
}

public class AptabaseService: AnalyticsService {
    public init() {}

    public func logEvent(name: String, args: [String: Any]) {}
}
