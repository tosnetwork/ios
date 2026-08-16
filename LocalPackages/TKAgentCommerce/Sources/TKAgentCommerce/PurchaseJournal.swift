import Foundation
import Darwin

public struct PurchaseJournalRecord: Codable, Equatable, Sendable {
    public static let schemaV1 = "tos.service.mobile-purchase-journal.v1"

    public let schema: String
    public let purchaseID: String
    public let phase: String
    public let fundingLeaseID: String?
    public let updatedAtUnix: UInt64

    private enum CodingKeys: String, CodingKey {
        case schema
        case purchaseID = "purchase_id"
        case phase
        case fundingLeaseID = "funding_lease_id"
        case updatedAtUnix = "updated_at_unix"
    }

    public init(purchaseID: String, phase: String, fundingLeaseID: String?, updatedAtUnix: UInt64) {
        self.schema = Self.schemaV1
        self.purchaseID = purchaseID
        self.phase = phase
        self.fundingLeaseID = fundingLeaseID
        self.updatedAtUnix = updatedAtUnix
    }
}

public enum PurchaseJournalError: Error, Equatable {
    case invalidPath
    case alreadyExists
    case missing
    case invalidRecord
    case illegalTransition
    case fundingLeaseUnavailable
    case persistenceFailed
}

/// A private, atomic journal for one purchase. The funding lease is durably
/// written before a caller is allowed to broadcast funding, so recovery at or
/// after that phase is reconciliation-only and can never silently re-pay.
public final class PurchaseJournal: @unchecked Sendable {
    private let fileURL: URL
    private let processLockURL: URL
    private let lock = NSLock()

    public init(directory: URL) throws {
        guard directory.isFileURL, directory.path == directory.standardizedFileURL.path else {
            throw PurchaseJournalError.invalidPath
        }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  (try manager.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType) == .typeDirectory else {
                throw PurchaseJournalError.invalidPath
            }
        } else {
            do {
                try manager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw PurchaseJournalError.persistenceFailed
            }
        }
        do {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw PurchaseJournalError.persistenceFailed
        }
        self.fileURL = directory.appendingPathComponent("purchase-journal.json", isDirectory: false)
        self.processLockURL = directory.appendingPathComponent("purchase-journal.lock", isDirectory: false)
    }

    public func create(purchaseID: String, nowUnix: UInt64) throws -> PurchaseJournalRecord {
        try lock.withLock { try withProcessLock {
            guard !FileManager.default.fileExists(atPath: fileURL.path) else {
                throw PurchaseJournalError.alreadyExists
            }
            let record = PurchaseJournalRecord(
                purchaseID: purchaseID,
                phase: "intent",
                fundingLeaseID: nil,
                updatedAtUnix: nowUnix
            )
            try persistValidated(record)
            return record
        } }
    }

    public func load() throws -> PurchaseJournalRecord {
        try lock.withLock { try withProcessLock { try loadUnlocked() } }
    }

    public func advance(to phase: String, nowUnix: UInt64) throws -> PurchaseJournalRecord {
        try lock.withLock { try withProcessLock {
            let current = try loadUnlocked()
            guard phase != "funding_lease",
                  PurchasePhase.canAdvance(from: current.phase, to: phase),
                  !(PurchasePhase.order(current.phase) < PurchasePhase.order("funding_lease") &&
                    PurchasePhase.order(phase) >= PurchasePhase.order("funding_lease")) else {
                throw PurchaseJournalError.illegalTransition
            }
            let next = PurchaseJournalRecord(
                purchaseID: current.purchaseID,
                phase: phase,
                fundingLeaseID: current.fundingLeaseID,
                updatedAtUnix: nowUnix
            )
            try persistValidated(next)
            return next
        } }
    }

    /// Atomically persists the unique lease before returning it to the caller.
    /// Only after this method succeeds may a funding message be broadcast.
    public func acquireFundingLease(id: String, nowUnix: UInt64) throws -> PurchaseJournalRecord {
        try lock.withLock { try withProcessLock {
            let current = try loadUnlocked()
            guard validIdentifier(id), current.fundingLeaseID == nil,
                  PurchasePhase.canAcquireFundingLease(current.phase) else {
                throw PurchaseJournalError.fundingLeaseUnavailable
            }
            let next = PurchaseJournalRecord(
                purchaseID: current.purchaseID,
                phase: "funding_lease",
                fundingLeaseID: id,
                updatedAtUnix: nowUnix
            )
            try persistValidated(next)
            return next
        } }
    }

    public func resumeAction() throws -> ResumeAction {
        PurchasePhase.resumeActionFor(try load().phase)
    }

    private func loadUnlocked() throws -> PurchaseJournalRecord {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { throw PurchaseJournalError.missing }
        do {
            let attributes = try manager.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 16_384 else {
                throw PurchaseJournalError.invalidRecord
            }
            let record = try JSONDecoder().decode(PurchaseJournalRecord.self, from: Data(contentsOf: fileURL))
            guard isValid(record) else { throw PurchaseJournalError.invalidRecord }
            return record
        } catch let error as PurchaseJournalError {
            throw error
        } catch {
            throw PurchaseJournalError.invalidRecord
        }
    }

    private func persistValidated(_ record: PurchaseJournalRecord) throws {
        guard isValid(record) else { throw PurchaseJournalError.invalidRecord }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            guard data.count <= 16_384 else { throw PurchaseJournalError.invalidRecord }
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.synchronize()
            try handle.close()
        } catch let error as PurchaseJournalError {
            throw error
        } catch {
            throw PurchaseJournalError.persistenceFailed
        }
    }

    private func withProcessLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = Darwin.open(
            processLockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw PurchaseJournalError.persistenceFailed }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(), (status.st_mode & S_IFMT) == S_IFREG,
              fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
              flock(descriptor, LOCK_EX) == 0 else {
            throw PurchaseJournalError.persistenceFailed
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func isValid(_ record: PurchaseJournalRecord) -> Bool {
        record.schema == PurchaseJournalRecord.schemaV1 &&
            validIdentifier(record.purchaseID) && PurchasePhase.order(record.phase) >= 0 &&
            ((PurchasePhase.order(record.phase) < PurchasePhase.order("funding_lease") && record.fundingLeaseID == nil) ||
             (PurchasePhase.order(record.phase) >= PurchasePhase.order("funding_lease") &&
              record.fundingLeaseID.map(validIdentifier) == true))
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 &&
            value.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
                    (byte >= 97 && byte <= 122) || byte == 45 || byte == 95
            }
    }
}
