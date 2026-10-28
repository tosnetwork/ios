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

    public init(baseDirectory: URL? = nil) throws {
        directory = try baseDirectory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("quantum-outbox", isDirectory: true)
        // The parent must already exist; otherwise its own new ancestors would
        // also need durable publication before the journal could promise safety.
        guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { throw Error.storage }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Error.storage }
        try FileManager.default.setAttributes([.posixPermissions: 0o700,
            .protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
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
        let url = path(identity)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw Error.storage
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: Self.maximumFileBytes + 1),
              data.count <= Self.maximumFileBytes else { throw Error.capacity }
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

    private func locked<T>(_ body: () throws -> T) throws -> T {
        Self.mutex.lock(); defer { Self.mutex.unlock() }
        let fd = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Error.storage }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Error.storage }
        defer { flock(fd, LOCK_UN) }
        // An uncertain write blocks every operation, including updates. Repeated
        // disk failures cannot accumulate unbounded orphan authorization files.
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard !files.contains(where: { $0.pathExtension == "pending" }) else { throw Error.storage }
        return try body()
    }
}
