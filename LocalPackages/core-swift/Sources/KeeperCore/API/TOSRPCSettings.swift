import Foundation

public enum TOSRPCSettings {
    public enum ValidationError: LocalizedError {
        case invalidEndpoint

        public var errorDescription: String? {
            "Enter a valid HTTP or HTTPS RPC address."
        }
    }

    private static let endpointKey = "network.tos.wallet.rpcEndpoint"
    /// Mirrors the bundled mainnet endpoint in DefaultRemoteConfiguration.json.
    /// Quantum RPC replies are still accepted only after verification against the selected profile.
    private static let defaultQuantumEndpoint = "https://rpc.tos.network"
    private static let debugQuantumEndpoint = "http://127.0.0.1:18545"

    public static var customEndpoint: String? {
        UserDefaults.standard.string(forKey: endpointKey)
    }

    public static var quantumEndpoint: String? {
        if let customEndpoint { return customEndpoint }
        #if DEBUG
        if let configured = ProcessInfo.processInfo.environment["TOS_RPC_URL"],
           let normalized = try? normalizedEndpoint(configured) {
            return normalized
        }
        return debugQuantumEndpoint
        #else
        return defaultQuantumEndpoint
        #endif
    }

    /// Builds the JSON-RPC URL, preserving either supported endpoint path when supplied in Settings.
    public static func jsonRPCEndpoint(for base: String) -> URL? {
        let endpoint = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lowercased = endpoint.lowercased()
        let url = lowercased.hasSuffix("/json_rpc") || lowercased.hasSuffix("/jsonrpc")
            ? endpoint
            : endpoint + "/jsonRPC"
        return URL(string: url)
    }

    @discardableResult
    public static func setCustomEndpoint(_ input: String) throws -> String? {
        guard let candidate = try normalizedEndpoint(input) else {
            reset()
            return nil
        }
        UserDefaults.standard.set(candidate, forKey: endpointKey)
        NotificationCenter.default.post(name: .tosRPCConfigurationChanged, object: nil)
        return candidate
    }

    private static func normalizedEndpoint(_ input: String) throws -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

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
              components.path.isEmpty || components.path.lowercased().hasSuffix("/json_rpc"),
              components.query == nil,
              components.fragment == nil
        else {
            throw ValidationError.invalidEndpoint
        }
        return candidate
    }

    public static func reset() {
        UserDefaults.standard.removeObject(forKey: endpointKey)
        NotificationCenter.default.post(name: .tosRPCConfigurationChanged, object: nil)
    }
}
