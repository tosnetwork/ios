import XCTest
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSQuantumBackupFileIdentityTests: XCTestCase {
    private let namespace = Data(repeating: 3, count: 32)
    private let root = Data(repeating: 4, count: 32)
    private let file = Data(repeating: 5, count: 32)
    private func authority(global: Int32 = -239, namespace: Data? = nil, key: UInt8 = 7) throws -> TOSQuantumSelfPayAuthority {
        try TOSQuantumSelfPayAuthority(globalID: global, namespace: namespace ?? self.namespace,
            primaryKey: Data(repeating: key, count: 1312), rescueKey: Data(repeating: 8, count: 32))
    }
    private func profile(global: Int32 = -239, root: UInt8 = 4, file: UInt8 = 5) throws -> TOSQuantumNetworkProfile {
        try TOSQuantumNetworkProfile(globalID: global,
            rootHash: String(repeating: String(format: "%02x", root), count: 32),
            fileHash: String(repeating: String(format: "%02x", file), count: 32))
    }
    private func fields(birth: Data, snapshot: Data) throws -> TOSQuantumBackupIdentityFields {
        try TOSQuantumBackupIdentityFields(globalID: -239, rootHash: root, fileHash: file,
            namespace: namespace, birthBOC: birth, authorityBOC: snapshot)
    }

    func testOriginalBirthPreservedAcrossSnapshotKeyChangeAndProfileBound() throws {
        let birth = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: authority()))
        let snapshot = try authority(key: 9)
        let metadata = try fields(birth: birth.toBOC(), snapshot: snapshot.cell.toBoc())
        let validated = try TOSQuantumBackupFileIdentity(fields: metadata, profile: profile(), expectedNamespace: namespace)
        XCTAssertEqual(validated.birth.address, birth.address)
        XCTAssertEqual(validated.snapshot.hash, snapshot.hash)
        XCTAssertNotEqual(validated.birth.address, try TOSQuantumSelfPayWallet(authority: snapshot).address)
        XCTAssertThrowsError(try TOSQuantumBackupFileIdentity(fields: metadata, profile: profile(global: -238), expectedNamespace: namespace))
        XCTAssertThrowsError(try TOSQuantumBackupFileIdentity(fields: metadata, profile: profile(root: 6), expectedNamespace: namespace))
        XCTAssertThrowsError(try TOSQuantumBackupFileIdentity(fields: metadata, profile: profile(file: 6), expectedNamespace: namespace))
        XCTAssertThrowsError(try TOSQuantumBackupFileIdentity(fields: metadata, profile: profile(), expectedNamespace: Data(count: 32)))
    }

    func testMalformedAndForeignBirthAndAuthorityRejected() throws {
        let good = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: authority())).toBOC()
        let foreign = try TOSQuantumSelfPayIdentity(wallet: TOSQuantumSelfPayWallet(authority: authority(global: -238))).toBOC()
        let snapshot = try authority().cell.toBoc()
        let foreignSnapshot = try authority(namespace: Data(count: 32)).cell.toBoc()
        for (birth, authority) in [(foreign, snapshot), (good, foreignSnapshot), (Data([1]), snapshot),
                                   (good, Data([1])), (good + Data([0]), snapshot), (good, snapshot + Data([0]))] {
            XCTAssertThrowsError(try TOSQuantumBackupFileIdentity(fields: fields(birth: birth, snapshot: authority),
                profile: profile(), expectedNamespace: namespace))
        }
    }
}
