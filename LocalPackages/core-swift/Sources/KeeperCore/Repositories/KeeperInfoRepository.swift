import CoreComponents
import Foundation

public protocol KeeperInfoRepository {
    func getKeeperInfo() throws -> KeeperInfo
    func getKeeperInfoIfPresent() throws -> KeeperInfo?
    func saveKeeperInfo(_ keeperInfo: KeeperInfo) throws
    func removeKeeperInfo() throws
}

public extension KeeperInfoRepository {
    /// Only a missing file means an empty wallet store. Corruption and read failures
    /// must not authorize replacing an existing wallet registry.
    func getKeeperInfoIfPresent() throws -> KeeperInfo? {
        do {
            return try getKeeperInfo()
        } catch FileSystemVault<KeeperInfo, String>.LoadError.noItem {
            return nil
        }
    }
}

extension FileSystemVault<KeeperInfo, String>: KeeperInfoRepository {
    public func getKeeperInfo() throws -> KeeperInfo {
        try loadItem(key: String.keeperInfoKey)
    }

    public func saveKeeperInfo(_ keeperInfo: KeeperInfo) throws {
        try saveItem(keeperInfo, key: .keeperInfoKey)
    }

    public func removeKeeperInfo() throws {
        try deleteItem(key: .keeperInfoKey)
    }
}

private extension String {
    static let keeperInfoKey = "KeeperInfo"
}
