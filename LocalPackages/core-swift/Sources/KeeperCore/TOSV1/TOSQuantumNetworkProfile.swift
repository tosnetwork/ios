import Foundation
import CoreComponents

/// A locally provisioned trust root, never discovered from the RPC being verified.
/// Editing this selection does not change the profile retained by an existing wallet.
public struct TOSQuantumNetworkProfile: Codable, Equatable {
    public let globalID: Int32
    public let rootHash: String
    public let fileHash: String

    public enum Error: LocalizedError {
        case invalidProfile, missingProfile, missingEndpoint
        public var errorDescription: String? {
            switch self {
            case .invalidProfile: return "Enter a signed 32-bit network ID and two 64-character hexadecimal genesis hashes."
            case .missingProfile: return "Configure the trusted Quantum network before creating a wallet."
            case .missingEndpoint: return "Configure a TOS RPC node before creating a Quantum wallet."
            }
        }
    }

    public init(globalID: Int32, rootHash: String, fileHash: String) throws {
        func hash(_ value: String) throws -> String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.utf8.count == 64,
                  normalized.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  normalized.contains(where: { $0 != "0" }) else { throw Error.invalidProfile }
            return normalized
        }
        self.globalID = globalID
        self.rootHash = try hash(rootHash)
        self.fileHash = try hash(fileHash)
    }

    private enum CodingKeys: String, CodingKey { case globalID, rootHash, fileHash }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(globalID: c.decode(Int32.self, forKey: .globalID),
                      rootHash: c.decode(String.self, forKey: .rootHash), fileHash: c.decode(String.self, forKey: .fileHash))
    }

    public func anchor() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["kind": "zerostate", "workchain": -1,
            "shard": "8000000000000000", "seqno": 0, "root_hash": rootHash, "file_hash": fileHash], options: [.sortedKeys])
    }

    private static let key = "network.tos.wallet.quantum.trustedNetwork.v1"
    public static func selected(defaults: UserDefaults = .standard) throws -> Self {
        guard let data = defaults.data(forKey: key) else { throw Error.missingProfile }
        guard data.count <= 1024 else { throw Error.invalidProfile }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func select(defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key)
    }
}

/// Retained before writing custody records. Failed registration leaves recovery
/// material intact rather than deleting keys after an ambiguous persistence failure.
public struct TOSQuantumCreationRecord: Codable {
    public let id: UUID
    public let profile: TOSQuantumNetworkProfile
    public let identity: TOSQuantumSelfPayIdentity
    public let account: UInt32
    public let generation: UInt32

    internal init(id: UUID, profile: TOSQuantumNetworkProfile, identity: TOSQuantumSelfPayIdentity) throws {
        guard identity.wallet.initialAuthority.globalID == profile.globalID, identity.wallet.walletID == 0 else {
            throw TOSPQError.keyBinding
        }
        self.id = id; self.profile = profile; self.identity = identity
        account = 0; generation = 0
    }

    private enum CodingKeys: String, CodingKey { case id, profile, identity, account, generation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(UInt32.self, forKey: .account) == 0,
              try c.decode(UInt32.self, forKey: .generation) == 0 else { throw TOSPQError.invalidInput }
        try self.init(id: c.decode(UUID.self, forKey: .id), profile: c.decode(TOSQuantumNetworkProfile.self, forKey: .profile),
                      identity: c.decode(TOSQuantumSelfPayIdentity.self, forKey: .identity))
    }

    public func save(baseDirectory: URL? = nil) throws {
        let base = try baseDirectory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        var directory = base.appendingPathComponent("quantum-creation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else {
            throw TOSPQError.invalidInput
        }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        // UUID is chosen once for a creation attempt. Never replace another attempt.
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent(id.uuidString + ".json"),
                                            options: [.withoutOverwriting, .completeFileProtection])
    }
}
