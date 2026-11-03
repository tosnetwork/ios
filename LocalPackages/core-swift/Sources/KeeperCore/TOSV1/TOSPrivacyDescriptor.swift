import Foundation

/// SHD1 receiving descriptor, matching shielded-pool-wallet::descriptor at d8e8f46c8.
/// Parsing validates the wire format and pool domain; it does not authenticate a payee.
public struct TOSPrivacyDescriptor: Equatable {
    public enum ValidationError: Error { case invalidEncoding, invalidDomain }
    public static let byteCount = 2573
    public let bytes: Data
    public var executionDomain: Data { bytes.subdata(in: 5..<37) }
    public var noteKeyIndex: UInt64 {
        bytes[37..<45].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    public var base64: String { bytes.base64EncodedString() }

    public init(base64 text: String, expectedDomain: Data) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count == 3432,
              let decoded = Data(base64Encoded: text),
              decoded.base64EncodedString() == text else {
            throw ValidationError.invalidEncoding
        }
        try self.init(bytes: decoded, expectedDomain: expectedDomain)
    }

    public init(bytes: Data, expectedDomain: Data) throws {
        guard bytes.count == Self.byteCount,
              Array(bytes.prefix(5)) == [0x53, 0x48, 0x44, 0x31, 1],
              Self.canonical(bytes.subdata(in: 5..<37)),
              Self.canonical(bytes.subdata(in: 45..<77)) else {
            throw ValidationError.invalidEncoding
        }
        guard expectedDomain.count == 32, bytes.subdata(in: 5..<37) == expectedDomain else {
            throw ValidationError.invalidDomain
        }
        self.bytes = bytes
    }

    private static func canonical(_ value: Data) -> Bool {
        let modulus: [UInt8] = [
            0x73, 0xed, 0xa7, 0x53, 0x29, 0x9d, 0x7d, 0x48,
            0x33, 0x39, 0xd8, 0x08, 0x09, 0xa1, 0xd8, 0x05,
            0x53, 0xbd, 0xa4, 0x02, 0xff, 0xfe, 0x5b, 0xfe,
            0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01
        ]
        return value.count == 32 && value.lexicographicallyPrecedes(modulus)
    }
}
