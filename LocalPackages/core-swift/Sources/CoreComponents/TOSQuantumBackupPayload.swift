import Foundation
import CryptoKit
import TonSwift

/// Unverified wire fields only. Parsing does not authorize signing or restore a current role.
final class TOSQuantumBackupPayload {
    struct Role {
        let role: UInt8
        let account: UInt32
        let generation: UInt32
        var seed: Data
        let publicKeyHash: Data
        let sourceProfile: UInt8
        var wordIndices: [UInt16]
        var phrasePassword: Data
        var master: Data

        mutating func wipe() {
            seed.resetBytes(in: 0..<seed.count)
            phrasePassword.resetBytes(in: 0..<phrasePassword.count)
            master.resetBytes(in: 0..<master.count)
            for index in wordIndices.indices { wordIndices[index] = 0 }
        }
    }

    let globalID: Int32
    let rootHash: Data
    let fileHash: Data
    let namespace: Data
    let birthBOC: Data
    let authorityBOC: Data
    private(set) var roles: [Role]

    func identityFields() throws -> TOSQuantumBackupIdentityFields {
        try TOSQuantumBackupIdentityFields(globalID: globalID, rootHash: rootHash, fileHash: fileHash,
            namespace: namespace, birthBOC: birthBOC, authorityBOC: authorityBOC)
    }

    private init(globalID: Int32, root: Data, file: Data, namespace: Data,
                 birth: Data, authority: Data, roles: [Role]) {
        self.globalID = globalID
        self.rootHash = root
        self.fileHash = file
        self.namespace = namespace
        self.birthBOC = birth
        self.authorityBOC = authority
        self.roles = roles
    }

    /// Best effort only: Swift value copies and runtime allocations cannot be guaranteed erased.
    func wipe() { for index in roles.indices { roles[index].wipe() } }
    deinit { wipe() }

    /// Binds every declared seed to the complete snapshot key, not just a file-supplied digest.
    /// Snapshot identity, provenance and fresh chain-role validation remain separate requirements.
    func validateSnapshotKeys(primary: Data, rescue: Data) throws {
        guard primary.count == TOSQuantumRole.primary.publicKeySize,
              rescue.count == TOSQuantumRole.rescue.publicKeySize else { throw TOSPQError.invalidInput }
        for entry in roles {
            guard let role = TOSQuantumRole(rawValue: Int32(entry.role)) else { throw TOSPQError.invalidInput }
            let derived = try TOSQuantumSigner.publicKey(role: role, seed: entry.seed)
            let expected = role == .primary ? primary : rescue
            guard constantTimeEqual(derived, expected),
                  constantTimeEqual(Data(SHA256.hash(data: derived)), entry.publicKeyHash) else {
                throw TOSPQError.keyBinding
            }
        }
    }

    /// Verifies only the declared source-to-seed mapping; this does not establish live authority.
    func validateProvenance() throws {
        for entry in roles {
            if entry.sourceProfile == 1 { continue } // Seed-only makes no mnemonic/master claim.
            var master = Data()
            defer { master.resetBytes(in: 0..<master.count) }
            switch entry.sourceProfile {
            case 2:
                guard entry.wordIndices.allSatisfy({ Int($0) < TonSwift.Mnemonic.words.count }) else {
                    throw TOSPQError.invalidInput
                }
                let words = entry.wordIndices.map { TonSwift.Mnemonic.words[Int($0)] }
                var password = entry.phrasePassword
                defer { password.resetBytes(in: 0..<password.count) }
                master = try TOSQuantumMnemonic.masterAndWipePassword(words: words, password: &password)
            case 3: master = entry.master
            default: throw TOSPQError.invalidInput
            }
            let material: TOSQuantumKdf.Material
            switch entry.role {
            case 1: material = .primary
            case 2: material = .rescue
            default: throw TOSPQError.invalidInput
            }
            var derived = try TOSQuantumKdf.deriveAndWipe(material: material, master: &master,
                network: namespace, globalID: globalID, account: entry.account, generation: entry.generation)
            defer { derived.resetBytes(in: 0..<derived.count) }
            guard constantTimeEqual(derived, entry.seed) else { throw TOSPQError.keyBinding }
        }
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }

    /// Wire encoding only; custody must first validate identity and role provenance.
    static func encodeUnverified(globalID: Int32, root: Data, file: Data, namespace: Data,
                                 birth: Data, authority: Data, roles: [Role]) throws -> Data {
        guard root.count == 32, file.count == 32, namespace.count == 32,
              (1...65536).contains(birth.count), (1...16384).contains(authority.count),
              (1...2).contains(roles.count) else { throw TOSPQError.invalidInput }
        var previous: UInt8 = 0
        for role in roles {
            guard (1...2).contains(role.role), role.role > previous,
                  role.seed.count == (role.role == 1 ? 32 : 48), role.publicKeyHash.count == 32 else {
                throw TOSPQError.invalidInput
            }
            previous = role.role
            switch role.sourceProfile {
            case 1:
                guard role.wordIndices.isEmpty, role.phrasePassword.isEmpty, role.master.isEmpty else {
                    throw TOSPQError.invalidInput
                }
            case 2:
                guard role.wordIndices.count == 12 || role.wordIndices.count == 24,
                      role.wordIndices.allSatisfy({ $0 < 2048 }), role.phrasePassword.count <= 1024,
                      role.master.isEmpty, validUTF8(role.phrasePassword) else { throw TOSPQError.invalidInput }
            case 3:
                guard role.master.count == 32, role.wordIndices.isEmpty, role.phrasePassword.isEmpty else {
                    throw TOSPQError.invalidInput
                }
            default: throw TOSPQError.invalidInput
            }
        }
        var output = Data()
        // All variable fields have been bounded before allocation or writing.
        output.reserveCapacity(1 + 4 + 96 + 4 + birth.count + 4 + authority.count + 1 + 4096)
        func append32(_ value: UInt32) {
            output.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 255),
                                      UInt8((value >> 8) & 255), UInt8(value & 255)])
        }
        func append16(_ value: UInt16) {
            output.append(contentsOf: [UInt8(value >> 8), UInt8(value & 255)])
        }
        output.append(1)
        append32(UInt32(bitPattern: globalID))
        output.append(root); output.append(file); output.append(namespace)
        append32(UInt32(birth.count)); output.append(birth)
        append32(UInt32(authority.count)); output.append(authority)
        output.append(UInt8(roles.count))
        for role in roles {
            output.append(role.role)
            append32(role.account); append32(role.generation)
            output.append(role.seed); output.append(role.publicKeyHash); output.append(role.sourceProfile)
            switch role.sourceProfile {
            case 2:
                output.append(1); output.append(UInt8(role.wordIndices.count))
                for word in role.wordIndices { append16(word) }
                append16(UInt16(role.phrasePassword.count)); output.append(role.phrasePassword)
            case 3: output.append(role.master)
            default: break
            }
        }
        guard output.count <= TOSQuantumBackupCipher.maximumPayload else {
            output.resetBytes(in: 0..<output.count)
            throw TOSPQError.invalidInput
        }
        return output
    }

    /// Caller must erase its authenticated plaintext input after parsing or failure.
    static func parseUnverified(_ plaintext: Data) throws -> TOSQuantumBackupPayload {
        var reader = try Reader(plaintext)
        guard try reader.byte() == 1 else { throw TOSPQError.invalidInput }
        let globalID = Int32(bitPattern: try reader.uint32())
        let root = try reader.fixed(32)
        let file = try reader.fixed(32)
        let namespace = try reader.fixed(32)
        let birth = try reader.blob(maximum: 65536)
        let authority = try reader.blob(maximum: 16384)
        let count = try reader.byte()
        guard (1...2).contains(count) else { throw TOSPQError.invalidInput }
        var roles: [Role] = []
        var previous: UInt8 = 0
        do {
            for _ in 0..<count {
                let role = try reader.byte()
                guard (1...2).contains(role), role > previous else { throw TOSPQError.invalidInput }
                previous = role
                let account = try reader.uint32()
                let generation = try reader.uint32()
                var seed = try reader.fixed(role == 1 ? 32 : 48)
                var words: [UInt16] = []
                var password = Data()
                var master = Data()
                defer {
                    seed.resetBytes(in: 0..<seed.count)
                    password.resetBytes(in: 0..<password.count)
                    master.resetBytes(in: 0..<master.count)
                    for index in words.indices { words[index] = 0 }
                }
                let hash = try reader.fixed(32)
                let source = try reader.byte()
                switch source {
                case 1: break
                case 2:
                    guard try reader.byte() == 1 else { throw TOSPQError.invalidInput }
                    let wordCount = try reader.byte()
                    guard wordCount == 12 || wordCount == 24 else { throw TOSPQError.invalidInput }
                    for _ in 0..<wordCount {
                        let word = try reader.uint16()
                        guard word < 2048 else { throw TOSPQError.invalidInput }
                        words.append(word)
                    }
                    let length = Int(try reader.uint16())
                    guard length <= 1024 else { throw TOSPQError.invalidInput }
                    password = try reader.fixed(length)
                    // Validate UTF-8 without creating an immutable password String.
                    guard validUTF8(password) else { throw TOSPQError.invalidInput }
                case 3: master = try reader.fixed(32)
                default: throw TOSPQError.invalidInput
                }
                roles.append(Role(role: role, account: account, generation: generation,
                    seed: seed, publicKeyHash: hash, sourceProfile: source,
                    wordIndices: words, phrasePassword: password, master: master))
            }
            guard reader.atEnd else { throw TOSPQError.invalidInput }
            return TOSQuantumBackupPayload(globalID: globalID, root: root, file: file,
                namespace: namespace, birth: birth, authority: authority, roles: roles)
        } catch {
            for index in roles.indices { roles[index].wipe() }
            throw error
        }
    }

    private static func validUTF8(_ bytes: Data) -> Bool {
        var iterator = bytes.makeIterator()
        var decoder = Unicode.UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    private struct Reader {
        let bytes: Data
        var offset = 0
        init(_ bytes: Data) throws {
            guard (1...TOSQuantumBackupCipher.maximumPayload).contains(bytes.count) else {
                throw TOSPQError.invalidInput
            }
            self.bytes = Data(bytes)
        }
        var atEnd: Bool { offset == bytes.count }
        mutating func fixed(_ count: Int) throws -> Data {
            guard count >= 0, count <= bytes.count - offset else { throw TOSPQError.invalidInput }
            defer { offset += count }
            return bytes.subdata(in: offset..<(offset + count))
        }
        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw TOSPQError.invalidInput }
            defer { offset += 1 }
            return bytes[offset]
        }
        mutating func uint16() throws -> UInt16 { (UInt16(try byte()) << 8) | UInt16(try byte()) }
        mutating func uint32() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 { value = (value << 8) | UInt32(try byte()) }
            return value
        }
        mutating func blob(maximum: Int) throws -> Data {
            let length = try uint32()
            guard length >= 1, length <= maximum else { throw TOSPQError.invalidInput }
            return try fixed(Int(length))
        }
    }
}
