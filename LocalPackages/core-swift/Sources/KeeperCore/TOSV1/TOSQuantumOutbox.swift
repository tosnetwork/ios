import Foundation
import Darwin
import TonSwift
import CoreComponents

/// Local authorization journal. A timeout, cancellation or wall clock never releases
/// an authorization that may have reached the signer. Settlement requires chain proof.
public final class TOSQuantumOutbox {
    public enum Phase: String, Codable { case reserved, signing, signed, submitting, unknown }
    public enum Error: Swift.Error { case occupied, invalidTransition, invalidRecord, capacity, storage }

    public struct Entry: Codable {
        public let version: UInt8
        public let id: UUID
        public let identity: TOSQuantumSelfPayIdentity
        public let profile: TOSQuantumNetworkProfile
        public let role: TOSQuantumRole
        public let requestBOC: Data
        public let requestHash: Data
        public let signingPublicKey: Data
        public let paymentIntent: TOSQuantumPaymentIntent?
        public let deploy: Bool
        public fileprivate(set) var phase: Phase
        public fileprivate(set) var signature: Data?
        public fileprivate(set) var signedBOC: Data?
        public fileprivate(set) var feeApproval: TOSQuantumPaymentQuote.Approval? = nil
    }

    private static let mutex = NSLock()
    private static let maximumFileBytes = 2 * 1024 * 1024
    private static let maximumMessageBytes = 1024 * 1024
    private let directory: URL
    private var retirementFault: ((RetirementFaultPoint) throws -> Void)?

    public init(baseDirectory: URL? = nil) throws {
        directory = try baseDirectory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("quantum-outbox", isDirectory: true)
        // Never change an existing foreign/nonprivate directory's attributes.
        let created = mkdir(directory.path, 0o700) == 0
        guard created || errno == EEXIST else { throw Error.storage }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else { throw Error.storage }
        if created {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
        }
        try syncDirectory()
        try syncDirectory(directory.deletingLastPathComponent())
        if baseDirectory == nil {
            // FileManager may also have just created Application Support. Publish
            // that entry in the container's existing Library directory as well.
            try syncDirectory(directory.deletingLastPathComponent().deletingLastPathComponent())
        }
    }

    /// One slot per birth identity, shared by PRIMARY/RESCUE and all local wallet IDs.
    /// A different trusted anchor cannot open another slot for the same wallet.
    public func reserve(identity: TOSQuantumSelfPayIdentity, profile: TOSQuantumNetworkProfile,
                        request: TOSQuantumSelfPayRequest, deploy: Bool,
                        paymentIntent: TOSQuantumPaymentIntent? = nil) throws -> Entry {
        try identity.requireNetwork(globalID: request.globalID, namespace: request.namespace)
        guard request.wallet == identity.address, profile.globalID == request.globalID else { throw Error.invalidRecord }
        try paymentIntent?.requireBound(request: request.request, role: request.role)
        let boc = try request.request.toBoc()
        guard boc.count <= Self.maximumMessageBytes else { throw Error.capacity }
        guard try TOSRPCOrdinaryBOC.decode(boc.base64EncodedString()).hash() == request.digest else {
            throw Error.invalidRecord
        }
        return try locked {
            guard try read(identity) == nil else { throw Error.occupied }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard files.filter({ $0.pathExtension == "json" }).count < 64 else { throw Error.capacity }
            let entry = Entry(version: 1, id: UUID(), identity: identity, profile: profile, role: request.role,
                requestBOC: boc, requestHash: request.digest, signingPublicKey: request.signingPublicKey,
                paymentIntent: paymentIntent, deploy: deploy, phase: .reserved)
            // Budget without relying on placeholder cell sharing or JSON slash
            // escaping. The actual signature can share fewer cells than zeros.
            var largest = entry
            let placeholder = Data(count: entry.role.signatureSize)
            largest.phase = .submitting
            largest.signature = placeholder
            _ = try message(entry, signature: placeholder) // same envelope depth/preflight as the real signature
            let maximum = try signedMessageUpperBound(request.request, identity: identity, deploy: deploy, role: entry.role)
            guard maximum <= Self.maximumMessageBytes else { throw Error.capacity }
            largest.signedBOC = Data(count: maximum)
            // Reserve bounded space for the later exact-message fee confirmation.
            guard try encode(largest).count <= Self.maximumFileBytes - 2048 else { throw Error.capacity }
            try write(entry)
            return entry
        }
    }

    public func pending(identity: TOSQuantumSelfPayIdentity) throws -> Entry? {
        try locked { try read(identity) }
    }

    /// Used after the user confirms the intent for local signing/estimation.
    /// This is not fee approval or permission to broadcast. It rechecks freshness
    /// and persists the visible intent before protected key access.
    public func reserve(payment: TOSQuantumPreparedPayment,
                        now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> Entry {
        try payment.requireFresh(now: now)
        return try reserve(identity: payment.identity, profile: payment.profile, request: payment.request,
            deploy: payment.requiresDeployment, paymentIntent: payment.intent)
    }

    /// Must complete durably before protected key access. A crash in the signer
    /// leaves `signing` occupied; recovery cannot sign a replacement automatically.
    @discardableResult
    public func beginSigning(_ entry: Entry) throws -> Entry {
        var result: Entry?
        try update(entry, allowed: [.reserved]) { current in
            current.phase = .signing; result = current
        }
        guard let result else { throw Error.invalidRecord }
        return result
    }

    /// The production custody path uses only the stored role/key/digest. Keychain
    /// cancellation or failure retains the signing slot rather than signing again.
    public func signReserved(_ entry: Entry, custody: TOSQuantumSeedKeychain,
                             walletID: UUID, context: TOSQuantumSeedKeychain.Context) throws {
        try signReserved(entry) { stored in
            try custody.sign(id: walletID, role: stored.role, context: context,
                expectedPublicKey: stored.signingPublicKey, purpose: .selfPay, digest: stored.requestHash)
        }
    }

    internal func signReserved(_ entry: Entry, signer: (Entry) throws -> Data) throws {
        let stored = try beginSigning(entry)
        try finishSigning(stored, signature: signer(stored))
    }

    /// Build and persist the exact envelope locally, never accepting a substituted
    /// broadcast message from the caller. No broadcaster is called by this store.
    public func finishSigning(_ entry: Entry, signature: Data) throws {
        try update(entry, allowed: [.signing]) { current in
            guard TOSQuantumSigner.verify(role: current.role, purpose: .selfPay,
                publicKey: current.signingPublicKey, digest: current.requestHash, signature: signature) else {
                throw Error.invalidRecord
            }
            current.signature = signature
            current.signedBOC = try message(current, signature: signature)
            current.phase = .signed
        }
    }

    /// The broadcaster receives bytes only after the attempt is durable. All
    /// retries use these same bytes, including recovery from `submitting`.
    public func beginSubmission(_ entry: Entry) throws -> Data {
        var result: Data?
        try update(entry, allowed: [.signed, .submitting, .unknown]) { current in
            guard current.paymentIntent == nil, let boc = current.signedBOC else { throw Error.invalidTransition }
            current.phase = .submitting; result = boc
        }
        guard let result else { throw Error.invalidRecord }
        return result
    }

    /// Payment broadcast requires a current native quote capability. Save both
    /// the fee confirmation and attempt before exposing any bytes to transport.
    internal func beginPaymentSubmission(_ entry: Entry, quote: TOSQuantumPaymentQuote, now: Int64) throws -> Data {
        var result: Data?
        try update(entry, allowed: [.signed, .submitting, .unknown]) { current in
            try quote.requireFresh(entry: current, now: now)
            guard let boc = current.signedBOC else { throw Error.invalidRecord }
            current.feeApproval = quote.approval
            current.phase = .submitting
            result = boc
        }
        guard let result else { throw Error.invalidRecord }
        return result
    }

    /// RPC acceptance is not inclusion. Both success and timeout retain the slot.
    public func markUnknown(_ entry: Entry) throws {
        try update(entry, allowed: [.submitting, .unknown]) { $0.phase = .unknown }
    }

    public func cancelUnsigned(_ entry: Entry) throws {
        try locked {
            guard let current = try read(entry.identity), current.id == entry.id,
                  current.phase == .reserved else { throw Error.invalidTransition }
            guard unlink(path(entry.identity).path) == 0 else { throw Error.storage }
            try syncDirectory()
        }
    }

    private func update(_ entry: Entry, allowed: [Phase], change: (inout Entry) throws -> Void) throws {
        try locked {
            guard var current = try read(entry.identity), current.id == entry.id,
                  allowed.contains(current.phase) else { throw Error.invalidTransition }
            try change(&current)
            try write(current)
        }
    }

    private func path(_ identity: TOSQuantumSelfPayIdentity) -> URL {
        directory.appendingPathComponent(identity.cell.hash().map { String(format: "%02x", $0) }.joined() + ".json")
    }

    private func external(_ entry: Entry, signature: Data) throws -> Cell {
        let request = try TOSRPCOrdinaryBOC.decode(entry.requestBOC.base64EncodedString())
        guard request.hash() == entry.requestHash else { throw Error.invalidRecord }
        let body = try Builder().store(ref: request).store(ref: TOSPQWallet.byteChain(signature)).endCell()
        return try entry.identity.wallet.external(body: body, deploy: entry.deploy)
    }

    private func message(_ entry: Entry, signature: Data) throws -> Data {
        let cell = try external(entry, signature: signature)
        let boc = try cell.toBoc()
        guard boc.count <= Self.maximumMessageBytes else { throw Error.capacity }
        guard try TOSRPCOrdinaryBOC.decode(boc.base64EncodedString()).hash() == cell.hash() else { throw Error.invalidRecord }
        return boc
    }

    /// BOC V3 upper bound: 4-byte cell references, 8-byte index entries and
    /// offsets exceed the widths needed by these preflight-bounded graphs.
    /// Hash deduplication can only reduce this bound, including signature sharing.
    private func signedMessageUpperBound(_ request: Cell, identity: TOSQuantumSelfPayIdentity,
                                         deploy: Bool, role: TOSQuantumRole) throws -> Int {
        var pending = [request], seen = Set<Data>(), bytes = 320 // header, external and submission cells
        if deploy { pending.append(identity.wallet.stateInit) }
        while let cell = pending.popLast() {
            guard seen.insert(cell.hash()).inserted else { continue }
            guard seen.count <= 32768 else { throw Error.capacity }
            bytes += 2 + (cell.bits.length + 7) / 8 + 4 * cell.refs.count + 8
            pending.append(contentsOf: cell.refs)
        }
        let signatureCells = (role.signatureSize + 126) / 127
        guard seen.count + signatureCells + 2 <= 16384 else { throw Error.capacity }
        return bytes + signatureCells * (2 + 127 + 4 + 8)
    }

    private func encode(_ entry: Entry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(entry)
    }

    private func read(_ identity: TOSQuantumSelfPayIdentity) throws -> Entry? {
        try readCanonical(identity)?.entry
    }
    private func readCanonical(_ identity: TOSQuantumSelfPayIdentity) throws -> (entry: Entry, raw: Data)? {
        guard let data = try retirementRead(path(identity), maximum: Self.maximumFileBytes) else { return nil }
        return (try decodeEntry(data, identity: identity), data)
    }
    private func decodeEntry(_ data: Data, identity: TOSQuantumSelfPayIdentity) throws -> Entry {
        let entry = try JSONDecoder().decode(Entry.self, from: data)
        guard entry.version == 1, entry.identity == identity, entry.profile.globalID == identity.wallet.initialAuthority.globalID,
              !entry.requestBOC.isEmpty, entry.requestBOC.count <= Self.maximumMessageBytes,
              entry.requestHash.count == 32, entry.signingPublicKey.count == entry.role.publicKeySize else { throw Error.invalidRecord }
        do { _ = try TOSQuantumStoredRequest(entry: entry) }
        catch { throw Error.invalidRecord }
        switch entry.phase {
        case .reserved, .signing:
            guard entry.signature == nil, entry.signedBOC == nil, entry.feeApproval == nil else { throw Error.invalidRecord }
        case .signed, .submitting, .unknown:
            guard let signature = entry.signature, signature.count == entry.role.signatureSize,
                  TOSQuantumSigner.verify(role: entry.role, purpose: .selfPay, publicKey: entry.signingPublicKey,
                      digest: entry.requestHash, signature: signature),
                  let boc = entry.signedBOC, boc.count <= Self.maximumMessageBytes,
                  try TOSRPCOrdinaryBOC.decode(boc.base64EncodedString()).hash() == external(entry, signature: signature).hash()
                  else { throw Error.invalidRecord }
        }
        if let approval = entry.feeApproval {
            guard [.submitting, .unknown].contains(entry.phase), let boc = entry.signedBOC,
                  let intent = entry.paymentIntent else { throw Error.invalidRecord }
            try approval.requireBound(message: boc, intent: intent)
        }
        return entry
    }

    private func write(_ entry: Entry) throws {
        let data = try encode(entry)
        guard data.count <= Self.maximumFileBytes else { throw Error.capacity }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".pending")
        // Preserve the temporary on any error: a failed fsync/rename has uncertain
        // durability and must not authorize another payment after restart.
        try data.write(to: temporary, options: [.withoutOverwriting, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let fd = open(temporary.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw Error.storage }
        let synced = fsync(fd) == 0 && fcntl(fd, F_FULLFSYNC) == 0
        close(fd)
        guard synced, rename(temporary.path, path(entry.identity).path) == 0 else { throw Error.storage }
        try syncDirectory()
    }

    private func syncDirectory(_ url: URL? = nil) throws {
        let fd = open((url ?? directory).path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Error.storage }
        defer { close(fd) }
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw Error.storage }
    }

    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        Self.mutex.lock(); defer { Self.mutex.unlock() }
        let fd = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Error.storage }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Error.storage }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        try withStoreLock {
            try retirementRequireNoGlobalPending()
            try retirementCleanupCompletedIfPresent()
            // Confirm absence of final cleanup metadata before permitting a new
            // reservation; a failed metadata-unlink dirsync is not guessed away.
            try syncDirectory()
            guard !retirementExists(retirementDescriptor), !retirementExists(retirementDescriptorNext),
                  !retirementExists(retirementWorkspace), !retirementExists(retirementStage),
                  !retirementExists(retirementDiagnostic) else { throw Error.storage }
            let history = try retirementHistoryRecords()
            guard !history.contains(where: { $0.publication == .releasePending }) else { throw Error.storage }
            return try body()
        }
    }
}

extension TOSQuantumOutbox {
    internal enum RetirementFaultPoint: String, CaseIterable, Hashable {
        case descriptorWrite, descriptorFileSync, descriptorRename, descriptorDirectorySync
        case stageMkdir, snapshotWrite, snapshotFileSync, decisionWrite, decisionFileSync, stageDirectorySync
        case workspaceRename, workspaceDirectorySync
        case resumeDescriptorFileSync, resumeDescriptorDirectorySync
        case materialEntryFileSync, materialDecisionFileSync, materialDirectorySync
        case pendingWrite, pendingFileSync, pendingRename, pendingHistoryDirectorySync, pendingWorkspaceDirectorySync
        case beforeCanonicalUnlink, canonicalUnlink, canonicalDirectorySync
        case completedWrite, completedFileSync, completedRename, completedHistoryDirectorySync, completedWorkspaceDirectorySync
        case cleanupCompletedFileSync, cleanupHistoryDirectorySync, cleanupWorkspaceDirectorySync
        case snapshotCleanup, decisionCleanup, workspaceRmdir, workspaceCleanupDirectorySync
        case descriptorCleanup, descriptorCleanupDirectorySync
        case stageRepairBeforeFreshCheck, stageDiagnosticSync, stageRepairSnapshotWrite
        case historyPruneUnlink, historyPruneDirectorySync
    }
    internal convenience init(baseDirectory: URL, retirementFault: @escaping (RetirementFaultPoint) throws -> Void) throws {
        try self.init(baseDirectory: baseDirectory); self.retirementFault = retirementFault
    }
    /// Not Codable and not publicly constructible. It carries the exact bytes
    /// read/validated from one FD; later proof work must revalidate this source.
    internal struct RetirementSource {
        internal let entry: Entry
        fileprivate let raw: Data
        fileprivate let store: String
        fileprivate let fromSnapshot: Bool
        fileprivate init(entry: Entry, raw: Data, store: String, fromSnapshot: Bool) {
            self.entry = entry; self.raw = raw; self.store = store; self.fromSnapshot = fromSnapshot
        }
    }
    internal enum RetirementInspection {
        case none
        case authorization(RetirementSource, recovering: Bool)
        case completed(TOSQuantumRetirementSummary)
    }
    private var retirementDescriptor: URL { directory.appendingPathComponent("retirement-descriptor.json") }
    private var retirementDescriptorNext: URL { directory.appendingPathComponent("retirement-descriptor.next") }
    private var retirementWorkspace: URL { directory.appendingPathComponent("retirement-workspace", isDirectory: true) }
    private var retirementStage: URL { directory.appendingPathComponent("retirement-stage", isDirectory: true) }
    private var retirementHistory: URL { directory.appendingPathComponent("retirement-history", isDirectory: true) }
    private var retirementDiagnostic: URL { directory.appendingPathComponent("retirement-repair.json") }
    private func retirementPoint(_ point: RetirementFaultPoint) throws { try retirementFault?(point) }
    private func retirementExists(_ url: URL) -> Bool { var value = stat(); return lstat(url.path, &value) == 0 }
    private func retirementStoreID() throws -> String {
        var value = stat()
        guard lstat(directory.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw Error.storage }
        return "\(value.st_dev):\(value.st_ino)"
    }
    private func retirementNames(_ folder: URL, maximum: Int) throws -> [String] {
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700,
              let handle = opendir(folder.path) else { throw Error.storage }
        defer { closedir(handle) }
        var result = [String]()
        while let item = readdir(handle) {
            let length = Int(item.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: length) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < maximum else { throw Error.capacity }
            result.append(name)
        }
        return result
    }
    /// One noFollow, nonblocking regular-file FD supplies both hash input and decoder input.
    private func retirementRead(_ file: URL, maximum: Int) throws -> Data? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return nil }; throw Error.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o7777 == 0o600,
              info.st_size >= 0, info.st_size <= maximum else { throw Error.storage }
        guard let data = try handle.read(upToCount: maximum + 1), data.count <= maximum else { throw Error.capacity }
        return data
    }
    private func retirementDirectory(_ url: URL) throws {
        let created = mkdir(url.path, 0o700) == 0
        guard created || errno == EEXIST else { throw Error.storage }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else { throw Error.storage }
        // Never chmod or change ownership/protection on an existing foreign path.
        if created {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            var protected = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protected.setResourceValues(values)
        }
        try syncDirectory(url); try syncDirectory(url.deletingLastPathComponent())
    }
    private func retirementFileSync(_ file: URL) throws {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Error.storage }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o7777 == 0o600,
              fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw Error.storage }
    }
    private func retirementWrite(_ data: Data, file: URL, maximum: Int,
                                 written: RetirementFaultPoint, synced: RetirementFaultPoint) throws {
        guard data.count <= maximum else { throw Error.capacity }
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Error.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var closed = false; defer { if !closed { try? handle.close() } }
        var info = stat()
        guard fchmod(fd, 0o600) == 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o7777 == 0o600 else { throw Error.storage }
        // Set protection before any bytes: a partial write is still a private,
        // known stage file, rather than a default-mode file later chmod'ed.
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        try handle.write(contentsOf: data); try retirementPoint(written)
        guard fsync(fd) == 0, fcntl(fd, F_FULLFSYNC) == 0 else { throw Error.storage }
        try retirementPoint(synced)
        try handle.close(); closed = true
    }
    private func retirementRequireNoGlobalPending() throws {
        let names = try retirementNames(directory, maximum: 128)
        guard !names.contains(where: { URL(fileURLWithPath: $0).pathExtension == "pending" }) else { throw Error.storage }
    }
    private func retirementLoadDescriptor() throws -> TOSQuantumRetirementCodec.Descriptor? {
        guard !retirementExists(retirementDescriptorNext) else { throw Error.storage }
        guard let bytes = try retirementRead(retirementDescriptor, maximum: TOSQuantumRetirementCodec.maximumDescriptorBytes) else { return nil }
        let value = try JSONDecoder().decode(TOSQuantumRetirementCodec.Descriptor.self, from: bytes)
        try value.validate(); return value
    }
    private func retirementRecordURL(_ operation: UUID) -> URL {
        retirementHistory.appendingPathComponent(operation.uuidString.lowercased() + ".json")
    }
    private func retirementRecord(_ operation: UUID) throws -> TOSQuantumRetirementSummary? {
        guard retirementExists(retirementHistory) else { return nil }
        _ = try retirementNames(retirementHistory, maximum: TOSQuantumRetirementCodec.maximumRecords)
        guard let bytes = try retirementRead(retirementRecordURL(operation), maximum: TOSQuantumRetirementCodec.maximumSummaryBytes) else { return nil }
        let value = try JSONDecoder().decode(TOSQuantumRetirementSummary.self, from: bytes)
        try value.validate()
        guard value.authorization.operationID == operation else { throw Error.invalidRecord }
        return value
    }
    private func retirementCheckBudget() throws {
        let code = TOSQuantumRetirementCodec.self
        var total = 0
        for folder in [retirementStage, retirementWorkspace] where retirementExists(folder) {
            let names = try retirementNames(folder, maximum: 3)
            guard Set(names).isSubset(of: ["entry.json", "decision.json", "summary.next"]) else { throw Error.invalidRecord }
            for name in names {
                let maximum = name == "entry.json" ? Self.maximumFileBytes : code.maximumSummaryBytes
                guard let value = try retirementRead(folder.appendingPathComponent(name), maximum: maximum) else { throw Error.storage }
                total += value.count
            }
        }
        var metadata = 0
        for file in [retirementDescriptor, retirementDescriptorNext, retirementDiagnostic] {
            let maximum = file == retirementDiagnostic ? code.maximumDiagnosticBytes : code.maximumDescriptorBytes
            if let bytes = try retirementRead(file, maximum: maximum) { metadata += bytes.count }
        }
        guard metadata <= 16 * 1024, total + metadata <= code.maximumWorkspaceBytes else { throw Error.capacity }
    }
}

extension TOSQuantumOutbox {
    private func retirementDescriptorState() throws -> (TOSQuantumRetirementCodec.Descriptor, staged: Bool)? {
        let final = try retirementRead(retirementDescriptor, maximum: TOSQuantumRetirementCodec.maximumDescriptorBytes)
        let next = try retirementRead(retirementDescriptorNext, maximum: TOSQuantumRetirementCodec.maximumDescriptorBytes)
        guard final == nil || next == nil else { throw Error.invalidRecord }
        guard let bytes = final ?? next else { return nil }
        let value = try JSONDecoder().decode(TOSQuantumRetirementCodec.Descriptor.self, from: bytes)
        try value.validate(); return (value, final == nil)
    }
    private func retirementValidateSnapshot(_ folder: URL, descriptor: TOSQuantumRetirementCodec.Descriptor,
                                            identity: TOSQuantumSelfPayIdentity) throws -> (Entry, Data) {
        guard let bytes = try retirementRead(folder.appendingPathComponent("entry.json"), maximum: Self.maximumFileBytes),
              TOSQuantumRetirementCodec.hash(bytes) == descriptor.snapshotFileHash else { throw Error.invalidRecord }
        let entry = try decodeEntry(bytes, identity: identity)
        try descriptor.decision.matches(TOSQuantumRetirementSummary.Authorization(entry))
        return (entry, bytes)
    }
    private func retirementValidateDecision(_ folder: URL, descriptor: TOSQuantumRetirementCodec.Descriptor) throws {
        guard let bytes = try retirementRead(folder.appendingPathComponent("decision.json"), maximum: TOSQuantumRetirementCodec.maximumSummaryBytes),
              TOSQuantumRetirementCodec.hash(bytes) == descriptor.decisionHash else { throw Error.invalidRecord }
        let value = try JSONDecoder().decode(TOSQuantumRetirementCodec.Decision.self, from: bytes)
        try value.validate(); guard value == descriptor.decision else { throw Error.invalidRecord }
    }
    private func retirementValidateCanonical(_ descriptor: TOSQuantumRetirementCodec.Descriptor,
                                              identity: TOSQuantumSelfPayIdentity, required: Bool) throws -> (entry: Entry, raw: Data)? {
        guard let current = try readCanonical(identity) else {
            guard !required else { throw Error.invalidRecord }; return nil
        }
        try descriptor.decision.matches(TOSQuantumRetirementSummary.Authorization(current.entry))
        guard TOSQuantumRetirementCodec.hash(current.raw) == descriptor.originalCanonicalFileHash else { throw Error.invalidRecord }
        return current
    }
    internal func inspectRetirement(identity: TOSQuantumSelfPayIdentity, profile: TOSQuantumNetworkProfile,
                                    operationID: UUID? = nil) throws -> RetirementInspection {
        try withStoreLock {
            try retirementRequireNoGlobalPending(); try retirementCheckBudget()
            let completed = try retirementCleanupCompletedIfPresent()
            if let (descriptor, _) = try retirementDescriptorState() {
                guard descriptor.decision.identityHash == identity.cell.hash(), descriptor.decision.profile == profile,
                      operationID == nil || operationID == descriptor.decision.operationID else { throw Error.occupied }
                let stage = retirementExists(retirementStage), workspace = retirementExists(retirementWorkspace)
                guard !(stage && workspace) else { throw Error.invalidRecord }
                if workspace {
                    let (entry, raw) = try retirementValidateSnapshot(retirementWorkspace, descriptor: descriptor, identity: identity)
                    try retirementValidateDecision(retirementWorkspace, descriptor: descriptor)
                    _ = try retirementValidateCanonical(descriptor, identity: identity, required: false)
                    if let record = try retirementRecord(entry.id) { try descriptor.matches(record) }
                    return .authorization(RetirementSource(entry: entry, raw: raw, store: try retirementStoreID(), fromSnapshot: true), recovering: true)
                }
                // Only a complete matching canonical can repair an initial known
                // stage. Partial snapshot bytes are never used as authorization.
                guard let canonical = try retirementValidateCanonical(descriptor, identity: identity, required: true),
                      try retirementRecord(canonical.entry.id) == nil else { throw Error.invalidRecord }
                if stage {
                    let names = try retirementNames(retirementStage, maximum: 3)
                    guard !names.contains("summary.next") else { throw Error.invalidRecord }
                    if names.contains("decision.json") {
                        let (entry, raw) = try retirementValidateSnapshot(retirementStage, descriptor: descriptor, identity: identity)
                        try retirementValidateDecision(retirementStage, descriptor: descriptor)
                        return .authorization(RetirementSource(entry: entry, raw: raw, store: try retirementStoreID(), fromSnapshot: true), recovering: true)
                    }
                }
                return .authorization(RetirementSource(entry: canonical.entry, raw: canonical.raw, store: try retirementStoreID(), fromSnapshot: false), recovering: true)
            }
            guard !retirementExists(retirementStage), !retirementExists(retirementWorkspace),
                  !retirementExists(retirementDiagnostic) else { throw Error.invalidRecord }
            let history = try retirementHistoryRecords()
            guard !history.contains(where: { $0.publication == .releasePending }) else { throw Error.invalidRecord }
            if let canonical = try readCanonical(identity) {
                guard canonical.entry.profile == profile, operationID == nil || canonical.entry.id == operationID else { throw Error.invalidRecord }
                return .authorization(RetirementSource(entry: canonical.entry, raw: canonical.raw, store: try retirementStoreID(), fromSnapshot: false), recovering: false)
            }
            if let completed, completed.authorization.identityHash == identity.cell.hash(), completed.authorization.profile == profile {
                return .completed(completed)
            }
            return .none
        }
    }
    internal func validateRetirementSource(_ source: RetirementSource) throws -> Entry {
        guard source.store == (try retirementStoreID()) else { throw Error.invalidRecord }
        switch try inspectRetirement(identity: source.entry.identity, profile: source.entry.profile, operationID: source.entry.id) {
        case .authorization(let current, _):
            try TOSQuantumAuthorizationBinding(source.entry).requireSame(current.entry)
            return current.entry
        case .none, .completed: throw Error.invalidTransition
        }
    }
    private func retirementPublishRecord(_ summary: TOSQuantumRetirementSummary, completed: Bool) throws {
        let codec = TOSQuantumRetirementCodec.self
        try summary.validate(); try retirementDirectory(retirementHistory)
        let destination = retirementRecordURL(summary.authorization.operationID)
        let temporary = retirementWorkspace.appendingPathComponent("summary.next")
        let data = try codec.encode(summary); guard data.count <= codec.maximumSummaryBytes else { throw Error.capacity }
        // This owned temporary contains only public summary metadata. The full
        // original entry remains in the workspace/canonical throughout retries.
        if retirementExists(temporary) {
            _ = try retirementRead(temporary, maximum: codec.maximumSummaryBytes)
            guard unlink(temporary.path) == 0 else { throw Error.storage }
            try syncDirectory(retirementWorkspace)
        }
        try retirementWrite(data, file: temporary, maximum: codec.maximumSummaryBytes,
            written: completed ? .completedWrite : .pendingWrite, synced: completed ? .completedFileSync : .pendingFileSync)
        try retirementCheckBudget()
        guard rename(temporary.path, destination.path) == 0 else { throw Error.storage }
        try retirementPoint(completed ? .completedRename : .pendingRename)
        try syncDirectory(retirementHistory); try retirementPoint(completed ? .completedHistoryDirectorySync : .pendingHistoryDirectorySync)
        try syncDirectory(retirementWorkspace); try retirementPoint(completed ? .completedWorkspaceDirectorySync : .pendingWorkspaceDirectorySync)
    }
    private func retirementRepairStageIfAllowed(descriptor: TOSQuantumRetirementCodec.Descriptor,
                                                canonical: (entry: Entry, raw: Data), expiry: TOSQuantumExpiredAuthorization,
                                                now: () -> Int64) throws {
        try retirementPoint(.stageRepairBeforeFreshCheck)
        // The boundary hook may model a crash/race after the caller's earlier
        // read. Re-read the actual same-op canonical before touching partial data.
        guard let current = try readCanonical(canonical.entry.identity) else { throw Error.invalidRecord }
        try expiry.requireBound(to: current.entry, now: now())
        try descriptor.decision.matches(TOSQuantumRetirementSummary.Authorization(current.entry))
        guard current.entry.id == descriptor.decision.operationID,
              TOSQuantumRetirementCodec.hash(current.raw) == descriptor.originalCanonicalFileHash,
              try retirementRecord(current.entry.id) == nil else { throw Error.invalidRecord }
        try retirementRequireNoGlobalPending()
        let names = try retirementNames(retirementStage, maximum: 3)
        guard Set(names).isSubset(of: ["entry.json"]) else { throw Error.invalidRecord }
        let snapshot = retirementStage.appendingPathComponent("entry.json")
        if let bytes = try retirementRead(snapshot, maximum: Self.maximumFileBytes) {
            struct Diagnostic: Codable { let version: UInt8; let operationID: UUID; let partialBytes: Int; let partialHash: Data }
            let diagnostic = Diagnostic(version: 1, operationID: current.entry.id, partialBytes: bytes.count,
                                        partialHash: TOSQuantumRetirementCodec.hash(bytes))
            let data = try TOSQuantumRetirementCodec.encode(diagnostic)
            guard data.count <= TOSQuantumRetirementCodec.maximumDiagnosticBytes else { throw Error.capacity }
            if retirementExists(retirementDiagnostic) {
                _ = try retirementRead(retirementDiagnostic, maximum: TOSQuantumRetirementCodec.maximumDiagnosticBytes)
                guard unlink(retirementDiagnostic.path) == 0 else { throw Error.storage }; try syncDirectory()
            }
            try retirementWrite(data, file: retirementDiagnostic, maximum: TOSQuantumRetirementCodec.maximumDiagnosticBytes,
                                 written: .stageDiagnosticSync, synced: .stageDiagnosticSync)
            try syncDirectory(); try retirementPoint(.stageDiagnosticSync)
            guard unlink(snapshot.path) == 0 else { throw Error.storage }; try syncDirectory(retirementStage)
        }
        try retirementWrite(current.raw, file: snapshot, maximum: Self.maximumFileBytes,
                             written: .stageRepairSnapshotWrite, synced: .snapshotFileSync)
    }
    private func retirementSyncMaterial(_ folder: URL, descriptor: TOSQuantumRetirementCodec.Descriptor,
                                        identity: TOSQuantumSelfPayIdentity) throws {
        _ = try retirementValidateSnapshot(folder, descriptor: descriptor, identity: identity)
        try retirementValidateDecision(folder, descriptor: descriptor)
        try retirementFileSync(folder.appendingPathComponent("entry.json")); try retirementPoint(.materialEntryFileSync)
        try retirementFileSync(folder.appendingPathComponent("decision.json")); try retirementPoint(.materialDecisionFileSync)
        try syncDirectory(folder); try retirementPoint(.materialDirectorySync)
    }
    /// The only canonical unlink in retirement. It always consumes a new private
    /// expiry capability against the locked, validated original authorization.
    internal func finishRetirement(_ source: RetirementSource, expiry: TOSQuantumExpiredAuthorization,
                                   receipt: TOSQuantumPaymentOutcomeReader.Receipt?, now: () -> Int64) throws -> TOSQuantumRetirementSummary {
        try withStoreLock {
            try retirementRequireNoGlobalPending(); try retirementCheckBudget()
            guard source.store == (try retirementStoreID()) else { throw Error.invalidRecord }
            if try retirementCleanupCompletedIfPresent() != nil { throw Error.invalidTransition }
            var descriptor: TOSQuantumRetirementCodec.Descriptor
            if let (existing, staged) = try retirementDescriptorState() {
                descriptor = existing
                try existing.decision.matches(TOSQuantumRetirementSummary.Authorization(source.entry))
                try expiry.requireBound(to: source.entry, now: now())
                if staged {
                    guard !retirementExists(retirementStage), !retirementExists(retirementWorkspace),
                          let canonical = try retirementValidateCanonical(existing, identity: source.entry.identity, required: true),
                          try retirementRecord(source.entry.id) == nil else { throw Error.invalidRecord }
                    try expiry.requireBound(to: canonical.entry, now: now())
                    try retirementFileSync(retirementDescriptorNext)
                    guard rename(retirementDescriptorNext.path, retirementDescriptor.path) == 0 else { throw Error.storage }
                    try retirementPoint(.descriptorRename); try syncDirectory(); try retirementPoint(.descriptorDirectorySync)
                }
            } else {
                guard !retirementExists(retirementStage), !retirementExists(retirementWorkspace),
                      let canonical = try readCanonical(source.entry.identity) else { throw Error.invalidRecord }
                try TOSQuantumAuthorizationBinding(source.entry).requireSame(canonical.entry)
                try expiry.requireBound(to: canonical.entry, now: now()); try receipt?.requireBound(to: canonical.entry)
                try retirementMakeHistoryRoom(excluding: canonical.entry.id)
                descriptor = try .init(entry: canonical.entry, rawCanonical: canonical.raw, now: now())
                let data = try TOSQuantumRetirementCodec.encode(descriptor)
                try retirementWrite(data, file: retirementDescriptorNext, maximum: TOSQuantumRetirementCodec.maximumDescriptorBytes,
                                     written: .descriptorWrite, synced: .descriptorFileSync)
                guard rename(retirementDescriptorNext.path, retirementDescriptor.path) == 0 else { throw Error.storage }
                try retirementPoint(.descriptorRename); try syncDirectory(); try retirementPoint(.descriptorDirectorySync)
            }
            let identity = source.entry.identity
            guard descriptor.decision.operationID == source.entry.id else { throw Error.invalidRecord }
            // Visibility after a failed rename/fsync is not durability. Reconfirm
            // every retained descriptor before relying on it for crash recovery.
            try retirementFileSync(retirementDescriptor); try retirementPoint(.resumeDescriptorFileSync)
            try syncDirectory(); try retirementPoint(.resumeDescriptorDirectorySync)
            if !retirementExists(retirementWorkspace) {
                guard let canonical = try retirementValidateCanonical(descriptor, identity: identity, required: true),
                      try retirementRecord(source.entry.id) == nil else { throw Error.invalidRecord }
                if !retirementExists(retirementStage) {
                    try retirementDirectory(retirementStage); try retirementPoint(.stageMkdir)
                }
                let stageNames = try retirementNames(retirementStage, maximum: 3)
                guard Set(stageNames).isSubset(of: ["entry.json", "decision.json"]) else { throw Error.invalidRecord }
                let decisionFile = retirementStage.appendingPathComponent("decision.json")
                if !retirementExists(decisionFile) {
                    let snapshotFile = retirementStage.appendingPathComponent("entry.json")
                    if retirementExists(snapshotFile) {
                        if (try? retirementValidateSnapshot(retirementStage, descriptor: descriptor, identity: identity)) == nil {
                            try retirementRepairStageIfAllowed(descriptor: descriptor, canonical: canonical, expiry: expiry, now: now)
                        }
                    } else {
                        try expiry.requireBound(to: canonical.entry, now: now())
                        try retirementWrite(canonical.raw, file: snapshotFile, maximum: Self.maximumFileBytes,
                                             written: .snapshotWrite, synced: .snapshotFileSync)
                    }
                    try retirementWrite(TOSQuantumRetirementCodec.encode(descriptor.decision), file: decisionFile,
                        maximum: TOSQuantumRetirementCodec.maximumSummaryBytes, written: .decisionWrite, synced: .decisionFileSync)
                }
                try retirementSyncMaterial(retirementStage, descriptor: descriptor, identity: identity)
                try syncDirectory(retirementStage); try retirementPoint(.stageDirectorySync); try syncDirectory()
                guard rename(retirementStage.path, retirementWorkspace.path) == 0 else { throw Error.storage }
                try retirementPoint(.workspaceRename); try syncDirectory(); try retirementPoint(.workspaceDirectorySync)
            }
            guard !retirementExists(retirementStage) else { throw Error.invalidRecord }
            let (entry, _) = try retirementValidateSnapshot(retirementWorkspace, descriptor: descriptor, identity: identity)
            try retirementValidateDecision(retirementWorkspace, descriptor: descriptor)
            try retirementSyncMaterial(retirementWorkspace, descriptor: descriptor, identity: identity)
            try TOSQuantumAuthorizationBinding(source.entry).requireSame(entry)
            try expiry.requireBound(to: entry, now: now()); try receipt?.requireBound(to: entry)
            _ = try retirementValidateCanonical(descriptor, identity: identity, required: false)
            let repair: TOSQuantumRetirementSummary.RepairDiagnostic?
            if let diagnosticBytes = try retirementRead(retirementDiagnostic, maximum: TOSQuantumRetirementCodec.maximumDiagnosticBytes) {
                repair = try JSONDecoder().decode(TOSQuantumRetirementSummary.RepairDiagnostic.self, from: diagnosticBytes)
                try repair?.validate(operation: entry.id)
            } else { repair = nil }
            let pending = try TOSQuantumRetirementSummary(entry: entry, decisionHash: descriptor.decisionHash,
                publication: .releasePending, expiry: expiry, receipt: receipt, repair: repair, now: now())
            try retirementPublishRecord(pending, completed: false)
            // Recheck after publication, immediately before the destructive syscall.
            try retirementPoint(.beforeCanonicalUnlink)
            let canonicalToRemove = try retirementValidateCanonical(descriptor, identity: identity, required: false)
            try expiry.requireBound(to: entry, now: now())
            if canonicalToRemove != nil {
                guard unlink(path(identity).path) == 0 else { throw Error.storage }
                try retirementPoint(.canonicalUnlink)
            }
            // ENOENT is never completion: a prior unlink can have failed its dirsync.
            try syncDirectory(); try retirementPoint(.canonicalDirectorySync)
            let completed = pending.completed()
            try retirementPublishRecord(completed, completed: true)
            _ = try retirementCleanupCompletedIfPresent()
            return completed
        }
    }
}

extension TOSQuantumOutbox {
    /// Completed JSON is only a locator for workspace cleanup. It is never
    /// supplied to canonical unlink or reconstructed into an expiry capability.
    @discardableResult
    private func retirementCleanupCompletedIfPresent() throws -> TOSQuantumRetirementSummary? {
        if retirementExists(retirementDescriptorNext) {
            guard !retirementExists(retirementDescriptor) else { throw Error.invalidRecord }
            return nil // Only a fresh-cap path may publish a staged descriptor.
        }
        guard let descriptor = try retirementLoadDescriptor() else { return nil }
        guard let record = try retirementRecord(descriptor.decision.operationID), record.publication == .releaseCompleted else { return nil }
        try descriptor.matches(record); try retirementCheckBudget()
        for folder in [retirementStage, retirementWorkspace] where retirementExists(folder) {
            let names = try retirementNames(folder, maximum: 3)
            guard Set(names).isSubset(of: ["entry.json", "decision.json", "summary.next"]) else { throw Error.invalidRecord }
            if let bytes = try retirementRead(folder.appendingPathComponent("entry.json"), maximum: Self.maximumFileBytes) {
                let decoded = try JSONDecoder().decode(Entry.self, from: bytes)
                _ = try decodeEntry(bytes, identity: decoded.identity)
                guard TOSQuantumRetirementCodec.hash(bytes) == descriptor.snapshotFileHash else { throw Error.invalidRecord }
                try descriptor.decision.matches(TOSQuantumRetirementSummary.Authorization(decoded))
            }
            if retirementExists(folder.appendingPathComponent("decision.json")) {
                try retirementValidateDecision(folder, descriptor: descriptor)
            }
        }
        // A visible completed rename may have preceded a failed directory sync.
        // Re-establish durability before deleting the only remaining snapshot.
        try retirementFileSync(retirementRecordURL(record.authorization.operationID)); try retirementPoint(.cleanupCompletedFileSync)
        try syncDirectory(retirementHistory); try retirementPoint(.cleanupHistoryDirectorySync)
        for folder in [retirementStage, retirementWorkspace] where retirementExists(folder) {
            let snapshot = folder.appendingPathComponent("entry.json"), decision = folder.appendingPathComponent("decision.json")
            if retirementExists(snapshot) { try retirementFileSync(snapshot); try retirementPoint(.materialEntryFileSync) }
            if retirementExists(decision) { try retirementFileSync(decision); try retirementPoint(.materialDecisionFileSync) }
            try syncDirectory(folder); try retirementPoint(.cleanupWorkspaceDirectorySync)
        }
        for folder in [retirementStage, retirementWorkspace] where retirementExists(folder) {
            for (name, point) in [("entry.json", RetirementFaultPoint.snapshotCleanup), ("decision.json", .decisionCleanup), ("summary.next", .decisionCleanup)] {
                let file = folder.appendingPathComponent(name)
                if retirementExists(file) {
                    _ = try retirementRead(file, maximum: name == "entry.json" ? Self.maximumFileBytes : TOSQuantumRetirementCodec.maximumSummaryBytes)
                    guard unlink(file.path) == 0 else { throw Error.storage }
                    try retirementPoint(point); try syncDirectory(folder)
                }
            }
            guard rmdir(folder.path) == 0 else { throw Error.storage }
            try retirementPoint(.workspaceRmdir); try syncDirectory(); try retirementPoint(.workspaceCleanupDirectorySync)
        }
        if retirementExists(retirementDiagnostic) {
            _ = try retirementRead(retirementDiagnostic, maximum: TOSQuantumRetirementCodec.maximumDiagnosticBytes)
            guard unlink(retirementDiagnostic.path) == 0 else { throw Error.storage }; try syncDirectory()
        }
        // The root descriptor survives entry/decision removal and workspace
        // rmdir+parent sync, so every partial cleanup still has its completed key.
        guard unlink(retirementDescriptor.path) == 0 else { throw Error.storage }
        try retirementPoint(.descriptorCleanup); try syncDirectory(); try retirementPoint(.descriptorCleanupDirectorySync)
        return record
    }
    private func retirementHistoryRecords() throws -> [TOSQuantumRetirementSummary] {
        guard retirementExists(retirementHistory) else { return [] }
        let names = try retirementNames(retirementHistory, maximum: TOSQuantumRetirementCodec.maximumRecords)
        var values = [TOSQuantumRetirementSummary](), total = 0
        for name in names {
            let url = URL(fileURLWithPath: name)
            guard url.pathExtension == "json", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  name == id.uuidString.lowercased() + ".json",
                  let bytes = try retirementRead(retirementHistory.appendingPathComponent(name), maximum: TOSQuantumRetirementCodec.maximumSummaryBytes)
                  else { throw Error.invalidRecord }
            total += bytes.count; guard total <= TOSQuantumRetirementCodec.maximumHistoryBytes else { throw Error.capacity }
            let value = try JSONDecoder().decode(TOSQuantumRetirementSummary.self, from: bytes)
            try value.validate(); guard value.authorization.operationID == id else { throw Error.invalidRecord }
            values.append(value)
        }
        return values
    }
    private func retirementActiveOperationIDs() throws -> Set<UUID> {
        try retirementRequireNoGlobalPending()
        var result = Set<UUID>()
        for name in try retirementNames(directory, maximum: 128) {
            guard name.range(of: "^[0-9a-f]{64}\\.json$", options: .regularExpression) != nil else { continue }
            guard let bytes = try retirementRead(directory.appendingPathComponent(name), maximum: Self.maximumFileBytes) else { throw Error.storage }
            let decoded = try JSONDecoder().decode(Entry.self, from: bytes)
            _ = try decodeEntry(bytes, identity: decoded.identity)
            let expected = decoded.identity.cell.hash().map { String(format: "%02x", $0) }.joined() + ".json"
            guard name == expected else { throw Error.invalidRecord }
            result.insert(decoded.id)
        }
        if let (descriptor, _) = try retirementDescriptorState() { result.insert(descriptor.decision.operationID) }
        else {
            guard !retirementExists(retirementStage), !retirementExists(retirementWorkspace),
                  !retirementExists(retirementDiagnostic) else { throw Error.invalidRecord }
        }
        return result
    }
    private func retirementPruneLocked(maximum: Int, excluding operation: UUID?) throws -> Int {
        guard (1...64).contains(maximum) else { throw Error.capacity }
        try retirementRequireNoGlobalPending()
        // Publish any prior root-metadata absence before deciding a completed
        // history record is unreferenced and can be durably forgotten.
        try syncDirectory()
        let active = try retirementActiveOperationIDs()
        let records = try retirementHistoryRecords().filter {
            $0.publication == .releaseCompleted && !active.contains($0.authorization.operationID) && $0.authorization.operationID != operation
        }.sorted {
            if $0.expiry.provenShardTime != $1.expiry.provenShardTime { return $0.expiry.provenShardTime < $1.expiry.provenShardTime }
            return $0.authorization.operationID.uuidString < $1.authorization.operationID.uuidString
        }
        var removed = 0
        for value in records.prefix(maximum) {
            let file = retirementRecordURL(value.authorization.operationID)
            guard unlink(file.path) == 0 else { throw Error.storage }
            try retirementPoint(.historyPruneUnlink)
            try syncDirectory(retirementHistory); try retirementPoint(.historyPruneDirectorySync)
            removed += 1
        }
        return removed
    }
    private func retirementMakeHistoryRoom(excluding operation: UUID) throws {
        try retirementDirectory(retirementHistory)
        let records = try retirementHistoryRecords()
        guard !records.contains(where: { $0.authorization.operationID == operation }) else { throw Error.invalidTransition }
        if records.count == TOSQuantumRetirementCodec.maximumRecords {
            guard try retirementPruneLocked(maximum: 1, excluding: operation) == 1 else { throw Error.capacity }
        }
    }
    internal func retirementHistory(identity: TOSQuantumSelfPayIdentity, profile: TOSQuantumNetworkProfile) throws -> [TOSQuantumRetirementSummary] {
        try withStoreLock {
            try retirementRequireNoGlobalPending()
            return try retirementHistoryRecords().filter {
                $0.authorization.identityHash == identity.cell.hash() && $0.authorization.profile == profile
            }.sorted { $0.expiry.provenShardTime > $1.expiry.provenShardTime }
        }
    }
    @discardableResult
    internal func pruneRetirementHistory(maximum: Int = 1) throws -> Int {
        try withStoreLock { try retirementPruneLocked(maximum: maximum, excluding: nil) }
    }
}
