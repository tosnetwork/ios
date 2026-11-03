import Foundation
import CoreFoundation
import BigInt
import CoreComponents

/// Complete native scan observation. It does not subtract local pending spends,
/// approve spending, or allocate scanNextIndex as a new receiving descriptor.
public struct TOSPrivacySummary: Equatable {
    public let totalOutputs: UInt64
    public let ownedOutputs: UInt64
    public let uniqueUnspentNotes: UInt64
    public let duplicateOutputs: UInt64
    public let reusedIndicesCount: UInt64
    public let diagnosticsCount: UInt64
    public let unspentBalance: String
    public let scanNextIndex: UInt64?

    /// Exact nano formatting of the already validated u128 decimal. No floating
    /// point conversion or ordinary-account 120-bit amount narrowing.
    public var formattedBalance: String {
        let padded = String(repeating: "0", count: max(0, 10 - unspentBalance.count)) + unspentBalance
        let split = padded.index(padded.endIndex, offsetBy: -9)
        let whole = String(padded[..<split])
        var fraction = String(padded[split...])
        while fraction.last == "0" { fraction.removeLast() }
        return fraction.isEmpty ? whole + " TOS" : whole + "." + fraction + " TOS"
    }

    internal init(nativeJSON: Data) throws {
        guard (1...8192).contains(nativeJSON.count),
              let object = try JSONSerialization.jsonObject(with: nativeJSON) as? [String: Any],
              Set(object.keys) == Set(["version", "total_outputs", "owned_outputs", "unique_unspent_notes",
                "duplicate_outputs", "reused_indices_count", "diagnostics_count", "unspent_balance", "scan_next_index"]),
              let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.stringValue == "1" else { throw TOSPQError.invalidInput }
        func counter(_ key: String) throws -> UInt64 {
            guard let text = object[key] as? String, (1...20).contains(text.utf8.count),
                  text.utf8.allSatisfy({ (48...57).contains($0) }), let number = UInt64(text),
                  String(number) == text else { throw TOSPQError.invalidInput }
            return number
        }
        totalOutputs = try counter("total_outputs"); ownedOutputs = try counter("owned_outputs")
        uniqueUnspentNotes = try counter("unique_unspent_notes"); duplicateOutputs = try counter("duplicate_outputs")
        reusedIndicesCount = try counter("reused_indices_count"); diagnosticsCount = try counter("diagnostics_count")
        guard ownedOutputs <= totalOutputs, diagnosticsCount <= totalOutputs,
              uniqueUnspentNotes <= ownedOutputs, duplicateOutputs <= ownedOutputs,
              reusedIndicesCount <= ownedOutputs,
              let amount = object["unspent_balance"] as? String, (1...39).contains(amount.utf8.count),
              amount.utf8.allSatisfy({ (48...57).contains($0) }), let number = BigUInt(amount),
              number.bitWidth <= 128, String(number) == amount,
              uniqueUnspentNotes != 0 || number == 0 else { throw TOSPQError.invalidInput }
        unspentBalance = amount
        scanNextIndex = object["scan_next_index"] is NSNull ? nil : try counter("scan_next_index")
    }
}
