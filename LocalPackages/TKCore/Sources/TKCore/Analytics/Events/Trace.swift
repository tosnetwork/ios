import Foundation

// TOS does not use Firebase Performance. No-op shell kept so call sites that
// create traces still compile.
public final class Trace {
    public init(name: String) {}

    public func setValue(_ value: String, forAttribute attribute: String) {}

    public func incrementMetric(_ name: String, by value: Int64) {}

    public func stop() {}
}
