import Foundation
import CoreFoundation
import CoreComponents

/// Issuer-controlled display fields. The URI comes from authenticated master content;
/// fetching it does not authenticate its JSON, issuer, balance or signing authority.
internal struct TOSTokenMetadata: Equatable {
    let name: String?
    let symbol: String?
    let decimals: Int
    static let maximumBytes = 65_536

    static func url(_ uri: String) throws -> URL {
        guard (1...2048).contains(uri.utf8.count) else { throw TOSPQError.invalidInput }
        let value = uri.hasPrefix("ipfs://") ? "https://ipfs.io/ipfs/" + String(uri.dropFirst(7)) : uri
        guard let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else { throw TOSPQError.invalidInput }
        return url
    }

    static func decode(_ bytes: Data) throws -> Self {
        guard (1...maximumBytes).contains(bytes.count), String(data: bytes, encoding: .utf8) != nil else {
            throw TOSPQError.invalidInput
        }
        try TOSQuantumRPCTransport.checkJSON(bytes, maximumDepth: 8)
        guard let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw TOSPQError.invalidInput }
        func field(_ key: String, cap: Int) throws -> String? {
            guard let raw = json[key], !(raw is NSNull) else { return nil }
            guard let value = raw as? String, value.utf8.count <= cap else { throw TOSPQError.invalidInput }
            return value.isEmpty ? nil : value
        }
        var precision = 9
        if let raw = json["decimals"] {
            let text: String
            if let value = raw as? String { text = value }
            else if let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                    ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: value.objCType)) {
                text = value.stringValue
            } else { throw TOSPQError.invalidInput }
            guard text.range(of: "^[0-9]{1,3}$", options: .regularExpression) != nil,
                  let number = Int(text), number <= 255 else { throw TOSPQError.invalidInput }
            precision = number
        }
        return try Self(name: field("name", cap: 128), symbol: field("symbol", cap: 32), decimals: precision)
    }

    static func read(_ uri: String, isCancelled: () -> Bool) throws -> Self {
        try decode(TOSQuantumRPCTransport.readTokenMetadata(url: url(uri), isCancelled: isCancelled))
    }
}
