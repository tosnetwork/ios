import Foundation
import Darwin
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

/// Public enrollment journal. It is never a signing or network trust capability.
public struct TOSQuantumCreationRecord: Codable {
    public let id: UUID
    public let profile: TOSQuantumNetworkProfile
    public let identity: TOSQuantumSelfPayIdentity
    public let account: UInt32
    public let generation: UInt32
    public let published: Bool

    internal init(id: UUID, profile: TOSQuantumNetworkProfile, identity: TOSQuantumSelfPayIdentity, published: Bool = false) throws {
        guard identity.wallet.initialAuthority.globalID == profile.globalID, identity.wallet.walletID == 0,
              identity.wallet.initialAuthority.policy == .ready else { throw TOSPQError.keyBinding }
        self.id = id; self.profile = profile; self.identity = identity
        account = 0; generation = 0; self.published = published
    }
    private enum CodingKeys: String, CodingKey { case id, profile, identity, account, generation, published }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(UInt32.self, forKey: .account) == 0,
              try c.decode(UInt32.self, forKey: .generation) == 0 else { throw TOSPQError.invalidInput }
        try self.init(id: c.decode(UUID.self, forKey: .id), profile: c.decode(TOSQuantumNetworkProfile.self, forKey: .profile),
            identity: c.decode(TOSQuantumSelfPayIdentity.self, forKey: .identity),
            published: c.decodeIfPresent(Bool.self, forKey: .published) ?? false)
    }

    public struct Entry {
        public let filename: String
        public let id: UUID?
        public let record: TOSQuantumCreationRecord?
        fileprivate init(file: URL) {
            filename = file.lastPathComponent
            id = file.pathExtension == "json" ? UUID(uuidString: file.deletingPathExtension().lastPathComponent) : nil
            record = try? TOSQuantumCreationRecord.read(file: file)
        }
    }
    public struct Scan {
        public let entries: [Entry]
        public let overflow: Bool
        public let storedCount: Int
    }
    private static let writeLock = NSLock()
    private static func directory(_ baseDirectory: URL?, create: Bool) throws -> URL {
        let base = try baseDirectory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: create)
        var directory = base.appendingPathComponent("quantum-creation", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else { throw TOSPQError.invalidInput }
        } catch CocoaError.fileReadNoSuchFile {
            if !create { return directory }
            throw TOSPQError.invalidInput
        }
        if create {
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        }
        return directory
    }
    private static func paths(directory: URL) throws -> ([URL], Bool) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], false) }
        var enumerationError: Swift.Error?
        guard let enumeration = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in enumerationError = error; return false }) else { throw TOSPQError.invalidInput }
        var files = [URL](), overflow = false
        for case let file as URL in enumeration {
            if files.count == 64 { overflow = true; break }
            files.append(file)
        }
        if let enumerationError { throw enumerationError }
        return (files, overflow)
    }
    private static func bytes(file: URL) throws -> Data {
        guard try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else { throw TOSPQError.invalidInput }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 32_769), data.count <= 32_768 else { throw TOSPQError.invalidInput }
        return data
    }
    private static func read(file: URL) throws -> Self {
        guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
              file.lastPathComponent == id.uuidString + ".json" else { throw TOSPQError.invalidInput }
        let record = try JSONDecoder().decode(Self.self, from: bytes(file: file))
        guard record.id == id else { throw TOSPQError.keyBinding }
        return record
    }
    public static func scan(baseDirectory: URL? = nil) throws -> Scan {
        writeLock.lock(); defer { writeLock.unlock() }
        let (files, overflow) = try paths(directory: directory(baseDirectory, create: false))
        return Scan(entries: files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).map(Entry.init(file:)), overflow: overflow, storedCount: files.count)
    }
    /// Strict diagnostic access. Production discovery isolates malformed entries.
    public static func loadAll(baseDirectory: URL? = nil) throws -> [Self] {
        let result = try scan(baseDirectory: baseDirectory)
        guard !result.overflow, result.entries.allSatisfy({ $0.record != nil }) else { throw TOSPQError.invalidInput }
        return result.entries.compactMap(\.record)
    }
    public static func load(id: UUID, baseDirectory: URL? = nil) throws -> Self {
        let directory = try directory(baseDirectory, create: false)
        return try read(file: directory.appendingPathComponent(id.uuidString + ".json"))
    }
    private static func atomicWrite(_ data: Data, file: URL, create: Bool) throws {
        guard data.count <= 32_768 else { throw TOSPQError.invalidInput }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".qcreation-" + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.withoutOverwriting, .completeFileProtection])
        if create {
            // A complete, closed file becomes visible with an exclusive link.
            // A crash during staging can never expose partial <UUID>.json bytes.
            try FileManager.default.linkItem(at: temporary, to: file)
        } else if Darwin.rename(temporary.path, file.path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    public func save(baseDirectory: URL? = nil) throws {
        Self.writeLock.lock(); defer { Self.writeLock.unlock() }
        let directory = try Self.directory(baseDirectory, create: true)
        let (files, overflow) = try Self.paths(directory: directory)
        guard !overflow, files.count < 64 else { throw TOSPQError.invalidInput }
        try Self.atomicWrite(JSONEncoder().encode(self), file: directory.appendingPathComponent(id.uuidString + ".json"), create: true)
    }
    public func markPublished(baseDirectory: URL? = nil) throws {
        Self.writeLock.lock(); defer { Self.writeLock.unlock() }
        let directory = try Self.directory(baseDirectory, create: false)
        let file = directory.appendingPathComponent(id.uuidString + ".json")
        let current = try Self.read(file: file)
        guard current.profile == profile, current.identity == identity else { throw TOSPQError.keyBinding }
        if current.published { return }
        // Preserve the original serialized QSI1 as well as its cell identity.
        guard var object = try JSONSerialization.jsonObject(with: Self.bytes(file: file)) as? [String: Any] else { throw TOSPQError.invalidInput }
        object["published"] = true
        try Self.atomicWrite(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), file: file, create: false)
    }
    public static func discard(_ entry: Entry, baseDirectory: URL? = nil) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard entry.filename != ".", entry.filename != "..", !entry.filename.contains("/") else { throw TOSPQError.invalidInput }
        let file = try directory(baseDirectory, create: false).appendingPathComponent(entry.filename)
        do { try FileManager.default.removeItem(at: file) }
        catch CocoaError.fileNoSuchFile { return }
    }
    public static func remove(id: UUID, baseDirectory: URL? = nil) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        let file = try directory(baseDirectory, create: false).appendingPathComponent(id.uuidString + ".json")
        do { try FileManager.default.removeItem(at: file) }
        catch CocoaError.fileNoSuchFile { return }
    }
    public static func removeAll(baseDirectory: URL? = nil) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        let directory = try directory(baseDirectory, create: false)
        do { try FileManager.default.removeItem(at: directory) }
        catch CocoaError.fileNoSuchFile { return }
    }
}
