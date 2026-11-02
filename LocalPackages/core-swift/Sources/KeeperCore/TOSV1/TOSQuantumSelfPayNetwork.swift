import Foundation
import TonSwift
import CoreComponents

/// Authenticated network identity for creating a self-pay wallet. The anchor is
/// provisioned locally by the proof session; a JSON-RPC response cannot mint this capability.
/// This does not attest to deployment, gas admission, or custody of either key.
public struct TOSQuantumSelfPayNetwork {
    public let globalID: Int32
    public let namespace: Data
    private let proof: TOSQuantumProofBridge.BoundRead
    private let policy: Cell
    private let maximumAge: Int64

    public static func request(maximumAge: Int64) throws -> Data {
        guard (1...3599).contains(maximumAge) else { throw TOSPQError.invalidInput }
        return try JSONSerialization.data(withJSONObject: [
            "mode": "live", "max_age_seconds": maximumAge, "config_params": [8, 19, 48]
        ], options: [.sortedKeys])
    }

    public init(proof: TOSQuantumProofBridge.BoundRead, expectedGlobalID: Int32,
                now: Int64, maximumAge: Int64) throws {
        guard (1...3599).contains(maximumAge) else { throw TOSPQError.invalidInput }
        try proof.requireLive(now: now, maximumAge: maximumAge)
        let version = try TOSRPCOrdinaryBOC.decode(proof.provenConfigParam(8).base64EncodedString())
        let identity = try TOSRPCOrdinaryBOC.decode(proof.provenConfigParam(19).base64EncodedString())
        let policy = try TOSRPCOrdinaryBOC.decode(proof.provenConfigParam(48).base64EncodedString())
        let namespace = try Self.validate(version: version, identity: identity, policy: policy,
                                          expectedGlobalID: expectedGlobalID,
                                          now: Self.policyTime(proof: proof, now: now))
        self.globalID = expectedGlobalID
        self.namespace = namespace
        self.proof = proof
        self.policy = policy
        self.maximumAge = maximumAge
    }

    // Pure schema validation is kept separate from the proof-only constructor.
    // Its return value is not an authenticated network capability.
    internal static func validate(version: Cell, identity: Cell, policy: Cell,
                                  expectedGlobalID: Int32, now: UInt32) throws -> Data {
        try TOSQuantumSelfPayAuthority.ordinary(version)
        let v = try version.beginParse()
        guard try v.loadUint(bits: 8) == 0xc4, try v.loadUint(bits: 32) >= 16 else {
            throw TOSPQError.invalidInput
        }
        try v.skip(64)
        try v.endParse()
        try TOSQuantumSelfPayAuthority.ordinary(identity)
        let i = try identity.beginParse()
        guard try i.loadInt(bits: 32) == Int64(expectedGlobalID) else { throw TOSPQError.keyBinding }
        try i.endParse()
        try TOSQuantumSelfPayAuthority.ordinary(policy)
        let p = try policy.beginParse()
        guard try p.loadUint(bits: 8) == 0xa1 else { throw TOSPQError.invalidInput }
        let namespace = try p.loadBytes(32)
        try TOSQuantumRetirementPolicy.requirePrimary(policy, network: namespace, now: now)
        return namespace
    }

    private static func policyTime(proof: TOSQuantumProofBridge.BoundRead, now: Int64) throws -> UInt32 {
        guard now > 0, now <= Int64(UInt32.max) else { throw TOSPQError.invalidInput }
        // A fresh block can precede a scheduled retirement. Do not create a
        // PRIMARY wallet after the deadline merely because that block is young.
        return max(UInt32(now), try proof.masterchainTime())
    }

    public func requireFresh(now: Int64) throws {
        try proof.requireLive(now: now, maximumAge: maximumAge)
        try TOSQuantumRetirementPolicy.requirePrimary(policy, network: namespace,
                                                      now: Self.policyTime(proof: proof, now: now))
    }

    /// An account read used with this network must name the identical anchor and block.
    public func requireSameCheckpoint(_ account: TOSQuantumProofBridge.BoundRead, now: Int64) throws {
        try requireFresh(now: now)
        try account.requireLive(now: now, maximumAge: maximumAge)
        try proof.requireSameCheckpoint(account)
    }

    public func makeIdentity(primaryKey: Data, rescueKey: Data, walletID: UInt32 = 0,
                             now: Int64) throws -> TOSQuantumSelfPayIdentity {
        try requireFresh(now: now)
        let authority = try TOSQuantumSelfPayAuthority(globalID: globalID, namespace: namespace,
                                                      primaryKey: primaryKey, rescueKey: rescueKey)
        return try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: authority, walletID: walletID))
    }
}
