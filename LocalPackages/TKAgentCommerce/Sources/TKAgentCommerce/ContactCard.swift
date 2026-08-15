import Foundation

/// NetworkTuple is the caller's configured TOS network a Contact Card must bind
/// to. A locator for another network is refused before any connection.
public struct NetworkTuple: Sendable, Equatable {
    public let networkID: String
    public let genesisRoot: String
    public let genesisFile: String
    public init(networkID: String, genesisRoot: String, genesisFile: String) {
        self.networkID = networkID
        self.genesisRoot = genesisRoot
        self.genesisFile = genesisFile
    }
}

/// ContactReason is the deterministic verdict of the stateless Contact Card
/// check performed before any endpoint connection. `.ok` means well-formed,
/// unexpired, and on the caller's network; the caller then verifies the ed25519
/// signature over `contactBytes` and, authoritatively, that the key controls the
/// Agent. Raw values match the shared vectors and the Go reference.
public enum ContactReason: String, Sendable {
    case ok
    case agentIDMalformed = "agent_id_malformed"
    case publicKeyMalformed = "public_key_malformed"
    case signatureMalformed = "signature_malformed"
    case endpointMalformed = "endpoint_malformed"
    case expiryInvalid = "expiry_invalid"
    case capabilityMalformed = "capability_malformed"
    case networkMismatch = "network_mismatch"
}

/// ContactLifetimeSeconds bounds how far in the future a Contact Card may expire.
public let contactLifetimeSeconds: UInt64 = 24 * 60 * 60

/// ContactCardFacts is a signed, non-canonical locator from a QR code or a
/// universal link.
public struct ContactCardFacts: Sendable, Equatable {
    public let agentID: String
    public let networkID: String
    public let genesisRoot: String
    public let genesisFile: String
    public let endpoint: String
    public let capabilities: [String]
    public let expiresAtUnix: UInt64
    public let publicKey: [UInt8]
    public let signature: [UInt8]

    public init(agentID: String, networkID: String, genesisRoot: String, genesisFile: String,
                endpoint: String, capabilities: [String], expiresAtUnix: UInt64,
                publicKey: [UInt8], signature: [UInt8]) {
        self.agentID = agentID
        self.networkID = networkID
        self.genesisRoot = genesisRoot
        self.genesisFile = genesisFile
        self.endpoint = endpoint
        self.capabilities = capabilities
        self.expiresAtUnix = expiresAtUnix
        self.publicKey = publicKey
        self.signature = signature
    }
}

public enum ContactCard {

    /// validateStateless applies the pre-connection checks in a fixed order. It
    /// performs no signature or resolver work; the caller verifies the ed25519
    /// signature over `contactBytes` after this passes.
    public static func validateStateless(_ card: ContactCardFacts, network: NetworkTuple, nowUnix: UInt64) -> ContactReason {
        if !isAgentID(card.agentID) { return .agentIDMalformed }
        if card.publicKey.count != 32 { return .publicKeyMalformed }
        if card.signature.count != 64 { return .signatureMalformed }
        if card.endpoint.trimmingCharacters(in: .whitespacesAndNewlines) != card.endpoint
            || !isValidEndpoint(card.endpoint) { return .endpointMalformed }
        if card.expiresAtUnix == 0 || nowUnix >= card.expiresAtUnix
            || card.expiresAtUnix > nowUnix + contactLifetimeSeconds { return .expiryInvalid }
        var seen = Set<String>()
        for capability in card.capabilities {
            if !isCapabilityID(capability) || seen.contains(capability) { return .capabilityMalformed }
            seen.insert(capability)
        }
        if card.networkID != network.networkID || card.genesisRoot != network.genesisRoot
            || card.genesisFile != network.genesisFile { return .networkMismatch }
        return .ok
    }

    /// contactBytes builds the ed25519 signing preimage. It must be byte-for-byte
    /// identical to the canonical issuer, or every signature check fails.
    public static func contactBytes(_ card: ContactCardFacts) -> [UInt8] {
        var out = [UInt8]("atos.agent.contact.v1\u{0}".utf8)
        func text(_ value: String) {
            let bytes = [UInt8](value.utf8)
            out.append(contentsOf: bigEndian32(UInt32(bytes.count)))
            out.append(contentsOf: bytes)
        }
        text(card.agentID)
        text(card.networkID)
        text(card.genesisRoot)
        text(card.genesisFile)
        text(card.endpoint)
        out.append(contentsOf: bigEndian32(UInt32(card.capabilities.count)))
        for capability in card.capabilities { text(capability) }
        out.append(contentsOf: bigEndian64(card.expiresAtUnix))
        out.append(contentsOf: card.publicKey)
        return out
    }
}

private func bigEndian32(_ value: UInt32) -> [UInt8] {
    [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
}

private func bigEndian64(_ value: UInt64) -> [UInt8] {
    stride(from: 56, through: 0, by: -8).map { UInt8((value >> UInt64($0)) & 0xff) }
}

private func isAgentID(_ value: String) -> Bool {
    value.hasPrefix("agent_") && isHex64(String(value.dropFirst("agent_".count)))
}

private func isCapabilityID(_ value: String) -> Bool {
    value.hasPrefix("cap_") && isHex64(String(value.dropFirst("cap_".count)))
}

private func isHex64(_ body: String) -> Bool {
    body.count == 64 && body.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }
}

private func isValidEndpoint(_ endpoint: String) -> Bool {
    guard let comps = URLComponents(string: endpoint), let scheme = comps.scheme,
          let host = comps.host, !host.isEmpty else { return false }
    if comps.user != nil || comps.password != nil || comps.query != nil || comps.fragment != nil { return false }
    if scheme == "https" { return true }
    if scheme == "http" { return host == "127.0.0.1" || host == "localhost" || host == "::1" }
    return false
}
