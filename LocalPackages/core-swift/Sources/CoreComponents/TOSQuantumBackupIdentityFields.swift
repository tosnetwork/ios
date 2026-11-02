import Foundation

/// Public file metadata only. None of these fields establish a trusted network or live authority.
public struct TOSQuantumBackupIdentityFields {
    public let globalID: Int32
    public let rootHash: Data
    public let fileHash: Data
    public let namespace: Data
    public let birthBOC: Data
    public let authorityBOC: Data

    public init(globalID: Int32, rootHash: Data, fileHash: Data, namespace: Data,
                birthBOC: Data, authorityBOC: Data) throws {
        guard rootHash.count == 32, fileHash.count == 32, namespace.count == 32,
              (1...65536).contains(birthBOC.count), (1...16384).contains(authorityBOC.count) else {
            throw TOSPQError.invalidInput
        }
        self.globalID = globalID
        self.rootHash = rootHash
        self.fileHash = fileHash
        self.namespace = namespace
        self.birthBOC = birthBOC
        self.authorityBOC = authorityBOC
    }
}
