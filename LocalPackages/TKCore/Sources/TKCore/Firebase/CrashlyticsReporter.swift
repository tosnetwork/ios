import Foundation

public protocol CrashlyticsReporting {
    func recordNonFatal(message: String, domain: String, metadata: [String: String])
}

// TOS does not use Firebase Crashlytics. No-op implementation kept so the
// logging backend and call sites compile.
public final class CrashlyticsReporter: CrashlyticsReporting {
    public init() {}

    public func recordNonFatal(message: String, domain: String, metadata: [String: String] = [:]) {}
}
