import Foundation
import CryptoKit
import BigInt
import CoreComponents
import TonSwift

/// Public local history data, not a proof capability. Decoding a saved record
/// never establishes a fresh receipt/expiry observation or permission to delete.
public struct TOSQuantumRetirementSummary: Codable, Equatable {
    public enum Publication: String, Codable { case releasePending = "release_pending", releaseCompleted = "release_completed" }
    public enum Outcome: String, Codable {
        case senderSent = "sender_sent"
        case includedWithoutExactTransfer = "included_without_exact_transfer"
        case expiredUnverified = "expired_unverified"
    }
    public struct Intent: Codable, Equatable {
        public let recipient: String
        public let amount: String
        public let bounce: Bool
        public let commentUTF8: Data?
        internal init(_ value: TOSQuantumPaymentIntent) {
            recipient = value.recipient.toRaw(); amount = String(value.amount); bounce = value.bounce
            commentUTF8 = value.comment.map { Data($0.utf8) }
        }
        internal func validate() throws {
            guard recipient.range(of: "^0:[0-9a-f]{64}$", options: .regularExpression) != nil,
                  amount.utf8.count <= 37, let coins = BigUInt(amount), String(coins) == amount,
                  coins > 0, coins.bitWidth <= 120,
                  (commentUTF8?.count ?? 0) <= TOSQuantumPaymentIntent.maximumCommentBytes,
                  commentUTF8 == nil || String(data: commentUTF8!, encoding: .utf8) != nil else { throw TOSQuantumOutbox.Error.invalidRecord }
        }
    }
    public struct Authorization: Codable, Equatable {
        public let operationID: UUID
        public let identityHash: Data
        public let address: String
        public let profile: TOSQuantumNetworkProfile
        public let role: TOSQuantumRole
        public let requestHash: Data
        public let requestBytesHash: Data
        public let authorityHash: Data
        public let epoch: String
        public let nonce: String
        public let deadline: UInt32
        public let deploy: Bool
        public let phase: TOSQuantumOutbox.Phase
        public let signaturePresent: Bool
        public let messagePresent: Bool
        public let messageBytesHash: Data?
        public let fingerprint: Data
        public let intent: Intent?
        internal init(_ entry: TOSQuantumOutbox.Entry) throws {
            let parsed = try TOSQuantumStoredRequest(entry: entry)
            operationID = entry.id; identityHash = entry.identity.cell.hash(); address = entry.identity.address.toRaw()
            profile = entry.profile; role = entry.role; requestHash = entry.requestHash
            requestBytesHash = TOSQuantumRetirementCodec.hash(entry.requestBOC); authorityHash = parsed.authorityHash
            epoch = String(parsed.epoch); nonce = String(parsed.nonce); deadline = parsed.deadline
            deploy = entry.deploy; phase = entry.phase; signaturePresent = entry.signature != nil
            messagePresent = entry.signedBOC != nil; messageBytesHash = entry.signedBOC.map(TOSQuantumRetirementCodec.hash)
            fingerprint = try TOSQuantumAuthorizationBinding(entry).fingerprint
            intent = entry.paymentIntent.map(Intent.init)
        }
        internal func validate() throws {
            guard identityHash.count == 32, requestHash.count == 32, requestBytesHash.count == 32,
                  authorityHash.count == 32, fingerprint.count == 32, deadline > 0,
                  address.range(of: "^0:[0-9a-f]{64}$", options: .regularExpression) != nil,
                  UInt64(epoch).map(String.init) == epoch, UInt64(nonce).map(String.init) == nonce,
                  messagePresent == (messageBytesHash != nil), (messageBytesHash?.count ?? 32) == 32,
                  signaturePresent == messagePresent,
                  ([TOSQuantumOutbox.Phase.reserved, .signing].contains(phase) ? !messagePresent : messagePresent)
                  else { throw TOSQuantumOutbox.Error.invalidRecord }
            try intent?.validate()
        }
    }
    public struct Provenance: Codable, Equatable {
        public let observedAt: Int64
        public let provenShardTime: UInt32
        public let masterchainTime: UInt32
        /// Authenticated target locator only; these bytes cannot reconstruct proof authority.
        public let targetRequest: Data
        internal func validate(address: String, deadline: UInt32) throws {
            guard observedAt > 0, provenShardTime > deadline, masterchainTime >= provenShardTime,
                  (1...2048).contains(targetRequest.count),
                  let value = try JSONSerialization.jsonObject(with: targetRequest) as? [String: Any],
                  value["mode"] as? String == "live", value["account"] as? String == address,
                  value["target"] is [String: Any] else { throw TOSQuantumOutbox.Error.invalidRecord }
        }
    }
    public struct Transaction: Codable, Equatable {
        public let hash: Data
        public let logicalTime: String
        public let timestamp: UInt32
        internal init(_ receipt: TOSQuantumPaymentOutcomeReader.Receipt) {
            hash = receipt.transactionHash; logicalTime = String(receipt.logicalTime); timestamp = receipt.timestamp
        }
    }
    public struct RepairDiagnostic: Codable, Equatable {
        public let version: UInt8
        public let operationID: UUID
        public let partialBytes: Int
        public let partialHash: Data
        internal func validate(operation: UUID) throws {
            guard version == 1, operationID == operation, (0...2 * 1024 * 1024).contains(partialBytes),
                  partialHash.count == 32 else { throw TOSQuantumOutbox.Error.invalidRecord }
        }
    }
    public let repair: RepairDiagnostic?
    public let version: UInt8
    public let authorization: Authorization
    public let decisionHash: Data
    public let publication: Publication
    public let outcome: Outcome
    public let transaction: Transaction?
    public let expiry: Provenance

    internal init(entry: TOSQuantumOutbox.Entry, decisionHash: Data, publication: Publication,
                  expiry: TOSQuantumExpiredAuthorization, receipt: TOSQuantumPaymentOutcomeReader.Receipt?,
                  repair: RepairDiagnostic? = nil, now: Int64) throws {
        try expiry.requireBound(to: entry, now: now)
        try receipt?.requireBound(to: entry)
        self.repair = repair
        version = 1; authorization = try Authorization(entry); self.decisionHash = decisionHash; self.publication = publication
        self.expiry = try expiry.retirementProvenance(entry: entry, now: now)
        transaction = receipt.map(Transaction.init)
        outcome = receipt.map { $0.outcome == .senderSent ? .senderSent : .includedWithoutExactTransfer } ?? .expiredUnverified
        try validate()
    }
    internal func completed() -> Self {
        Self(version: version, authorization: authorization, decisionHash: decisionHash, publication: .releaseCompleted,
             outcome: outcome, transaction: transaction, expiry: expiry, repair: repair)
    }
    private init(version: UInt8, authorization: Authorization, decisionHash: Data, publication: Publication,
                 outcome: Outcome, transaction: Transaction?, expiry: Provenance, repair: RepairDiagnostic?) {
        self.version = version; self.authorization = authorization; self.decisionHash = decisionHash
        self.publication = publication; self.outcome = outcome; self.transaction = transaction; self.expiry = expiry; self.repair = repair
    }
    internal func validate() throws {
        guard version == 1, decisionHash.count == 32,
              (outcome == .expiredUnverified) == (transaction == nil) else { throw TOSQuantumOutbox.Error.invalidRecord }
        try authorization.validate(); try expiry.validate(address: authorization.address, deadline: authorization.deadline)
        try repair?.validate(operation: authorization.operationID)
        if let transaction {
            guard authorization.intent != nil, authorization.messagePresent, transaction.hash.count == 32, UInt64(transaction.logicalTime).map(String.init) == transaction.logicalTime,
                  transaction.logicalTime != "0", transaction.timestamp <= expiry.provenShardTime else { throw TOSQuantumOutbox.Error.invalidRecord }
        }
    }
}

internal enum TOSQuantumRetirementCodec {
    static let maximumSummaryBytes = 64 * 1024
    static let maximumDescriptorBytes = 6 * 1024
    static let maximumDiagnosticBytes = 4 * 1024
    static let maximumRecords = 64
    static let maximumHistoryBytes = maximumRecords * maximumSummaryBytes
    static let maximumWorkspaceBytes = 2 * 1024 * 1024 + 2 * maximumSummaryBytes + 16 * 1024
    static func hash(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    struct Decision: Codable, Equatable {
        let version: UInt8
        let action: String
        let operationID: UUID
        let identityHash: Data
        let address: String
        let profile: TOSQuantumNetworkProfile
        let fingerprint: Data
        let authorizationDataHash: Data
        let requestedAt: Int64
        init(entry: TOSQuantumOutbox.Entry, now: Int64) throws {
            let authorization = try TOSQuantumRetirementSummary.Authorization(entry)
            version = 1; action = "finish_original_authorization"; operationID = entry.id
            identityHash = authorization.identityHash; address = authorization.address; profile = entry.profile
            fingerprint = authorization.fingerprint; authorizationDataHash = TOSQuantumRetirementCodec.hash(try TOSQuantumRetirementCodec.encode(authorization)); requestedAt = now
        }
        func validate() throws {
            guard version == 1, action == "finish_original_authorization", requestedAt > 0,
                  identityHash.count == 32, fingerprint.count == 32, authorizationDataHash.count == 32,
                  address.range(of: "^0:[0-9a-f]{64}$", options: .regularExpression) != nil else { throw TOSQuantumOutbox.Error.invalidRecord }
        }
        func matches(_ authorization: TOSQuantumRetirementSummary.Authorization) throws {
            try authorization.validate()
            guard operationID == authorization.operationID, identityHash == authorization.identityHash,
                  address == authorization.address, profile == authorization.profile, fingerprint == authorization.fingerprint,
                  authorizationDataHash == TOSQuantumRetirementCodec.hash(try TOSQuantumRetirementCodec.encode(authorization)) else { throw TOSQuantumOutbox.Error.invalidRecord }
        }
    }
    struct Descriptor: Codable, Equatable {
        let version: UInt8
        let originalCanonicalFileHash: Data
        let snapshotFileHash: Data
        let decision: Decision
        let decisionHash: Data
        init(entry: TOSQuantumOutbox.Entry, rawCanonical: Data, now: Int64) throws {
            version = 1; originalCanonicalFileHash = TOSQuantumRetirementCodec.hash(rawCanonical); snapshotFileHash = TOSQuantumRetirementCodec.hash(rawCanonical)
            decision = try Decision(entry: entry, now: now); decisionHash = TOSQuantumRetirementCodec.hash(try TOSQuantumRetirementCodec.encode(decision))
        }
        func validate() throws {
            guard version == 1, originalCanonicalFileHash.count == 32, snapshotFileHash.count == 32,
                  decisionHash == TOSQuantumRetirementCodec.hash(try TOSQuantumRetirementCodec.encode(decision)) else { throw TOSQuantumOutbox.Error.invalidRecord }
            try decision.validate()
        }
        func matches(_ summary: TOSQuantumRetirementSummary) throws {
            try summary.validate()
            try decision.matches(summary.authorization)
            guard summary.decisionHash == decisionHash else { throw TOSQuantumOutbox.Error.invalidRecord }
        }
    }
}
