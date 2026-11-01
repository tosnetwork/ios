import Foundation

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
