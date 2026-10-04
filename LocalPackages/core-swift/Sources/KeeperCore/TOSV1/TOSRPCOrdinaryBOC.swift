import Foundation
import TonSwift

/// Validate the ordinary, single-root V3 BOCs returned by the TOS JSON-RPC
/// before invoking the pinned SDK, whose root/reference indexing is unchecked.
/// This bounded mobile RPC format is not a general-purpose BOC codec.
/// Indexed and CRC32C forms are accepted; absent cells, cache/hash flags,
/// exotic or higher-level cells and excessive size/depth are rejected.
enum TOSRPCOrdinaryBOC {
    private static let maximumBytes = 1_048_576
    private static let maximumCells = 16_384
    private static let maximumDepth = 1_023

    static func decode(_ encoded: String) throws -> Cell {
        guard encoded.utf8.count <= ((maximumBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: encoded), data.count <= maximumBytes else {
            throw TOSRPCClient.Error.invalidResponse
        }
        try preflight(data)
        guard let cells = try? Cell.fromBoc(src: data), cells.count == 1,
              cells[0].type == .ordinary, cells[0].level == 0 else {
            throw TOSRPCClient.Error.invalidResponse
        }
        return cells[0]
    }

    private static func preflight(_ data: Data) throws {
        var reader = Reader(bytes: Array(data))
        guard try reader.uint(4) == 0xb5ee9c72 else { throw TOSRPCClient.Error.invalidResponse }
        let flags = try reader.uint(1)
        let size = flags & 7
        let offsetSize = try reader.uint(1)
        guard flags & 0x38 == 0, (1...4).contains(size), (1...4).contains(offsetSize) else {
            throw TOSRPCClient.Error.invalidResponse
        }
        let cells = try reader.uint(size)
        let roots = try reader.uint(size)
        let absent = try reader.uint(size)
        let cellBytes = try reader.uint(offsetSize)
        guard (1...maximumCells).contains(cells), roots == 1, absent == 0,
              cellBytes <= maximumBytes, cells <= cellBytes / 2,
              try reader.uint(size) == 0 else { throw TOSRPCClient.Error.invalidResponse }
        var index = [Int]()
        if flags & 0x80 != 0 {
            for _ in 0..<cells { index.append(try reader.uint(offsetSize)) }
        }
        let checksumBytes = flags & 0x40 != 0 ? 4 : 0
        guard reader.bytes.count - reader.offset == cellBytes + checksumBytes else {
            throw TOSRPCClient.Error.invalidResponse
        }
        let start = reader.offset
        let end = start + cellBytes
        var starts = [Int]()
        var ends = [Int]()
        var references = [[Int]]()
        var reachable = Array(repeating: false, count: cells)
        reachable[0] = true
        for cell in 0..<cells {
            starts.append(reader.offset - start)
            let descriptor = try reader.uint(1)
            let bitsDescriptor = try reader.uint(1)
            // Bits 3/4/5... indicate exotic cells, stored hashes or levels.
            guard descriptor & 0xf8 == 0, descriptor <= 4 else { throw TOSRPCClient.Error.invalidResponse }
            let bytes = (bitsDescriptor + 1) / 2
            guard bytes <= end - reader.offset else { throw TOSRPCClient.Error.invalidResponse }
            if bitsDescriptor & 1 != 0 {
                guard bytes > 0 else { throw TOSRPCClient.Error.invalidResponse }
                let last = reader.bytes[reader.offset + bytes - 1]
                // A non-byte-aligned cell has 1...7 payload bits in its final
                // byte, followed by a nonzero top-up marker and zero padding.
                guard last & 0x7f != 0,
                      bytes * 8 - last.trailingZeroBitCount - 1 <= 1_023 else {
                    throw TOSRPCClient.Error.invalidResponse
                }
            }
            try reader.skip(bytes)
            var refs = [Int]()
            for _ in 0..<descriptor {
                let reference = try reader.uint(size)
                guard reference > cell, reference < cells else { throw TOSRPCClient.Error.invalidResponse }
                refs.append(reference)
                if reachable[cell] { reachable[reference] = true }
            }
            guard reader.offset <= end else { throw TOSRPCClient.Error.invalidResponse }
            references.append(refs)
            ends.append(reader.offset - start)
        }
        guard reader.offset == end, !reachable.contains(false),
              index.isEmpty || index == starts || index == ends else {
            throw TOSRPCClient.Error.invalidResponse
        }
        var depths = Array(repeating: 0, count: cells)
        for cell in (0..<cells).reversed() {
            let depth = references[cell].map { depths[$0] + 1 }.max() ?? 0
            guard depth <= maximumDepth else { throw TOSRPCClient.Error.invalidResponse }
            depths[cell] = depth
        }
        // The SDK verifies the CRC32C value after this structural preflight.
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func uint(_ count: Int) throws -> Int {
            guard (1...4).contains(count), count <= bytes.count - offset else {
                throw TOSRPCClient.Error.invalidResponse
            }
            var value = 0
            for _ in 0..<count {
                value = (value << 8) | Int(bytes[offset])
                offset += 1
            }
            return value
        }

        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= bytes.count - offset else { throw TOSRPCClient.Error.invalidResponse }
            offset += count
        }
    }
}
