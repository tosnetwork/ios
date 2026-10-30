import Foundation

/// Private per-wallet checkpoint. Enrollment requires locally authenticated anchor provisioning.
/// A verified result does not establish wallet authorization until account/configuration binding.
public final class TOSQuantumProofSession {
    private let anchor: Data
    private let directory: URL
    public init(walletID: UUID, locallyProvisionedAnchor: Data, baseDirectory: URL? = nil) throws {
        guard (1...1_048_576).contains(locallyProvisionedAnchor.count),
              let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw TOSPQError.invalidInput }
        anchor = locallyProvisionedAnchor
        let parent = base.appendingPathComponent("quantum-proof-checkpoints", isDirectory: true)
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
    public func enroll(request: Data, now: Int64, material: [TOSQuantumProofBridge.Material]) throws -> Data {
        try TOSQuantumProofBridge.verifyPersisted(directory: directory, initialize: true, anchor: anchor, request: request, now: now, material: material)
    }
    public func read(request: Data, now: Int64, material: [TOSQuantumProofBridge.Material]) throws -> Data {
        try TOSQuantumProofBridge.verifyPersisted(directory: directory, initialize: false, anchor: anchor, request: request, now: now, material: material)
    }
    public func enroll(request: Data, now: Int64, transport: @escaping TOSQuantumProofBridge.Transport) throws -> Data {
        try TOSQuantumProofBridge.acquirePersisted(directory: directory, initialize: true, anchor: anchor, request: request, now: now, transport: transport)
    }
    public func read(request: Data, now: Int64, transport: @escaping TOSQuantumProofBridge.Transport) throws -> Data {
        try TOSQuantumProofBridge.acquirePersisted(directory: directory, initialize: false, anchor: anchor, request: request, now: now, transport: transport)
    }

    public func enrollBound(request: Data, now: Int64, transport: @escaping TOSQuantumProofBridge.Transport) throws -> TOSQuantumProofBridge.BoundRead {
        try TOSQuantumProofBridge.acquireBound(directory: directory, initialize: true, anchor: anchor, request: request, now: now, transport: transport)
    }
    public func readBound(request: Data, now: Int64, transport: @escaping TOSQuantumProofBridge.Transport) throws -> TOSQuantumProofBridge.BoundRead {
        try TOSQuantumProofBridge.acquireBound(directory: directory, initialize: false, anchor: anchor, request: request, now: now, transport: transport)
    }

    /// Uses the existing enrollment and the same cross-process checkpoint lock.
    /// A signed message must already be durable in the outbox; this call neither
    /// broadcasts it nor releases its authorization slot, even on refusal.
    public func simulate(request: Data, now: Int64, signedMessage: Data,
                         transport: @escaping TOSQuantumProofBridge.Transport) throws -> TOSQuantumProofBridge.LocalSimulation {
        try TOSQuantumProofBridge.simulatePersisted(directory: directory, anchor: anchor, request: request,
            now: now, signedMessage: signedMessage, transport: transport)
    }

    public static func removeCheckpoint(walletID: UUID, baseDirectory: URL? = nil) throws {
        try removeCheckpointDirectory(walletID: walletID, baseDirectory: baseDirectory)
    }
    public static func removeAllCheckpoints(baseDirectory: URL? = nil) throws {
        try removeCheckpointDirectory(walletID: nil, baseDirectory: baseDirectory)
    }
    private static func removeCheckpointDirectory(walletID: UUID?, baseDirectory: URL?) throws {
        guard let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw TOSPQError.invalidInput }
        let parent = base.appendingPathComponent("quantum-proof-checkpoints", isDirectory: true)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else { throw TOSPQError.invalidInput }
        } catch CocoaError.fileReadNoSuchFile { return }
        let target = walletID.map { parent.appendingPathComponent($0.uuidString, isDirectory: true) } ?? parent
        do { try FileManager.default.removeItem(at: target) }
        catch CocoaError.fileNoSuchFile { return }
    }

}
