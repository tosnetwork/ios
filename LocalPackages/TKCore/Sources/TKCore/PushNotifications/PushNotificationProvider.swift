import Foundation

// TOS does not use Firebase Cloud Messaging. No-op token provider kept so the
// push notification manager compiles; it never produces a token, so push
// subscription is effectively disabled until a TOS push backend exists.
public final class PushNotificationTokenProvider: NSObject {
    public var didUpdateToken: ((String?) -> Void)?

    public func setup() {}

    public func getToken() async -> String? {
        nil
    }
}
