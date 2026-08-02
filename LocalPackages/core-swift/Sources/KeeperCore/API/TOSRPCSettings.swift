import Foundation

public enum TOSRPCSettings {
    public enum ValidationError: LocalizedError {
        case invalidEndpoint

        public var errorDescription: String? {
            "Enter a valid HTTP or HTTPS RPC address."
        }
    }

    private static let endpointKey = "network.tos.wallet.rpcEndpoint"

    public static var customEndpoint: String? {
        UserDefaults.standard.string(forKey: endpointKey)
    }

    @discardableResult
    public static func setCustomEndpoint(_ input: String) throws -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reset()
            return nil
        }

        var candidate = trimmed
        if !candidate.contains("://") {
            candidate = "http://" + candidate
        }

        while candidate.hasSuffix("/") {
            candidate.removeLast()
        }
        if candidate.lowercased().hasSuffix("/jsonrpc") {
            candidate.removeLast("/jsonRPC".count)
        }

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw ValidationError.invalidEndpoint
        }

        UserDefaults.standard.set(candidate, forKey: endpointKey)
        return candidate
    }

    public static func reset() {
        UserDefaults.standard.removeObject(forKey: endpointKey)
    }
}
