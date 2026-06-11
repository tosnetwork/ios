import Foundation

// TOS does not use Firebase. This is a no-op shell kept so existing call sites
// compile; the Firebase SDKs have been removed.
public final class FirebaseConfigurator: NSObject {
    public static let configurator = FirebaseConfigurator()

    override private init() {}

    public func configure() {}
}
