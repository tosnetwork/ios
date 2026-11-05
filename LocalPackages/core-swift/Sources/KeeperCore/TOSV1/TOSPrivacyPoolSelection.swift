import Foundation
import TonSwift
import CoreComponents

/// Explicitly provisioned expectations, independent of the RPC being checked.
/// Construction is local validation, not proof of deployment or user acceptance.
public struct TOSPrivacyPoolSelection {
    public let profile: TOSQuantumNetworkProfile
    public let address: Address
    public let sourceDescription: String
    internal let code: Cell
    internal let profileHash: Data
    internal let manifestHash: Data
    internal let verifyingKeyHash: Data

    public init(profile: TOSQuantumNetworkProfile, address: Address, codeBOC: Data,
                profileHash: Data, manifestHash: Data, verifyingKeyHash: Data,
                sourceDescription: String) throws {
        guard address.workchain == 0, address.hash.count == 32, (1...65536).contains(codeBOC.count),
              [profileHash, manifestHash, verifyingKeyHash].allSatisfy({ $0.count == 32 }),
              (1...256).contains(sourceDescription.utf8.count) else { throw TOSPQError.invalidInput }
        code = try TOSRPCOrdinaryBOC.decode(codeBOC.base64EncodedString())
        self.profile = profile; self.address = address; self.profileHash = profileHash
        self.manifestHash = manifestHash; self.verifyingKeyHash = verifyingKeyHash
        self.sourceDescription = sourceDescription
    }
}

/// Empty by default. Only an approved application/network configuration injects
/// entries. No RPC discovery, imported backup, or observed code can register trust.
public final class TOSPrivacyPoolRegistry {
    public static let shared = TOSPrivacyPoolRegistry()
    private let lock = NSLock()
    private var entries: [TOSPrivacyPoolSelection] = []
    public init() {}
    public func registerApproved(_ selection: TOSPrivacyPoolSelection) throws {
        lock.lock(); defer { lock.unlock() }
        guard entries.count < 8 || entries.contains(where: { $0.profile == selection.profile }) else {
            throw TOSPQError.invalidInput
        }
        entries.removeAll { $0.profile == selection.profile }; entries.append(selection)
    }
    public func selection(for profile: TOSQuantumNetworkProfile) -> TOSPrivacyPoolSelection? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.profile == profile }
    }
}
