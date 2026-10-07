import Foundation

/// Private per-wallet checkpoint. Enrollment requires locally authenticated anchor provisioning.
/// A verified result does not establish wallet authorization until account/configuration binding.
public final class TOSV5R2ProofSession {
    private let anchor: Data
    private let directory: URL
    public init(walletID: UUID, locallyProvisionedAnchor: Data, baseDirectory: URL? = nil) throws {
        guard (1...1_048_576).contains(locallyProvisionedAnchor.count),
              let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw TOSPQError.invalidInput }
        anchor = locallyProvisionedAnchor
        let parent = base.appendingPathComponent("v5r2-proof-checkpoints", isDirectory: true)
        try Self.prepare(parent)
        directory = parent.appendingPathComponent(walletID.uuidString, isDirectory: true)
        try Self.prepare(directory)
    }
    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else { throw TOSPQError.invalidInput }
        var url = directory, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    public func enroll(request: Data, now: Int64, material: [TOSV5R2ProofBridge.Material]) throws -> Data {
        try TOSV5R2ProofBridge.verifyPersisted(directory: directory, initialize: true, anchor: anchor, request: request, now: now, material: material)
    }
    public func read(request: Data, now: Int64, material: [TOSV5R2ProofBridge.Material]) throws -> Data {
        try TOSV5R2ProofBridge.verifyPersisted(directory: directory, initialize: false, anchor: anchor, request: request, now: now, material: material)
    }
    public func enroll(request: Data, now: Int64, transport: @escaping TOSV5R2ProofBridge.Transport) throws -> Data {
        try TOSV5R2ProofBridge.acquirePersisted(directory: directory, initialize: true, anchor: anchor, request: request, now: now, transport: transport)
    }
    public func read(request: Data, now: Int64, transport: @escaping TOSV5R2ProofBridge.Transport) throws -> Data {
        try TOSV5R2ProofBridge.acquirePersisted(directory: directory, initialize: false, anchor: anchor, request: request, now: now, transport: transport)
    }

    public func enrollBound(request: Data, now: Int64, transport: @escaping TOSV5R2ProofBridge.Transport) throws -> TOSV5R2ProofBridge.BoundRead {
        try TOSV5R2ProofBridge.acquireBound(directory: directory, initialize: true, anchor: anchor, request: request, now: now, transport: transport)
    }
    public func readBound(request: Data, now: Int64, transport: @escaping TOSV5R2ProofBridge.Transport) throws -> TOSV5R2ProofBridge.BoundRead {
        try TOSV5R2ProofBridge.acquireBound(directory: directory, initialize: false, anchor: anchor, request: request, now: now, transport: transport)
    }

}
