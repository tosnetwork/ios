import BigInt
import Foundation
import TonSwift

public struct TOSDNSResolutionEvidence: Equatable {
    public let canonicalName: String
    public let resolvedAddress: String
    public let resolverPath: [String]
    public let masterchainSequence: UInt64
    public let rootHash: String
    public let fileHash: String
    public let observedAt: UInt64
    public let lastFillUpTime: UInt64
    public let renewalDeadline: UInt64
}

enum TOSDNSError: LocalizedError, Equatable {
    case invalidName(String)
    case invalidResponse(String)
    case notFound
    case unsafeLifecycle

    var errorDescription: String? {
        switch self {
        case let .invalidName(reason): "Invalid .tos name: \(reason)"
        case let .invalidResponse(reason): "TOS DNS verification failed: \(reason)"
        case .notFound: "The .tos name has no wallet record."
        case .unsafeLifecycle: "The .tos name is auctioning, unfinalized, or past its renewal deadline."
        }
    }
}

enum TOSDNSRules {
    static let leaseSeconds: UInt64 = 31_622_400
    static let maximumContacts = 8
    static let maximumCheckpointAge: UInt64 = 120
    static let walletCategory = "105311596331855300602201538317979276640056460191511695660591596829410056223515"

    static func canonicalName(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 126, !trimmed.hasSuffix("."), !trimmed.hasPrefix("."),
              trimmed == trimmed.lowercased(), trimmed.hasSuffix(".tos")
        else { throw TOSDNSError.invalidName("use lowercase ASCII without a trailing dot") }
        let labels = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.allSatisfy { byte in
                byte >= 0x61 && byte <= 0x7A || byte >= 0x30 && byte <= 0x39 || byte == 0x2D
            }
        }) else { throw TOSDNSError.invalidName("labels may contain only a-z, 0-9, and hyphen") }
        return trimmed
    }

    static func encode(_ canonical: String) -> Data {
        let labels = canonical.split(separator: ".")
        return Data(labels.reversed().flatMap { Array($0.utf8) + [0] })
    }

    static func isComponentBoundary(consumedBytes: Int, query: Data) -> Bool {
        consumedBytes == query.count || consumedBytes > 0 &&
            (query[query.index(query.startIndex, offsetBy: consumedBytes - 1)] == 0 ||
             query[query.index(query.startIndex, offsetBy: consumedBytes)] == 0)
    }

    static func renewalDeadline(lastFillUpTime: UInt64, blockTime: UInt64) throws -> UInt64 {
        guard lastFillUpTime > 0, lastFillUpTime <= UInt64.max - leaseSeconds else {
            throw TOSDNSError.invalidResponse("invalid renewal clock")
        }
        let deadline = lastFillUpTime + leaseSeconds
        guard blockTime <= deadline else { throw TOSDNSError.unsafeLifecycle }
        return deadline
    }

    static func validateCheckpointTime(_ blockTime: UInt64, now: UInt64) throws {
        let difference = blockTime > now ? blockTime - now : now - blockTime
        guard difference <= maximumCheckpointAge else {
            throw TOSDNSError.invalidResponse("finalized checkpoint is stale or the device clock is wrong")
        }
    }
}

private struct DNSCheckpoint: Equatable {
    let sequence: UInt64
    let rootHash: String
    let fileHash: String
}

private struct TOSDNSResolver {
    typealias Call = (String, [String: Any]) async throws -> [String: Any]
    let call: Call

    func resolveWallet(_ input: String) async throws -> TOSDNSResolutionEvidence {
        let name = try TOSDNSRules.canonicalName(input)
        let label = String(name.split(separator: ".")[name.split(separator: ".").count - 2])
        let consensus = try await call("getConsensusBlock", [:])
        let sequence = uint(consensus["consensus_block"])
        let observedAt = uint(consensus["timestamp"])
        guard sequence > 0, observedAt > 0 else { throw TOSDNSError.invalidResponse("invalid finalized checkpoint") }
        let now = UInt64(Date().timeIntervalSince1970)
        try TOSDNSRules.validateCheckpointTime(observedAt, now: now)

        let config = try await call("getConfigParam", ["param": 4, "seqno": sequence])
        let root = try configRoot(config)
        var remaining = TOSDNSRules.encode(name)
        var current = root
        var path: [String] = []
        var seen: Set<String> = []
        var checkpoint: DNSCheckpoint?
        var terminal: Cell?

        while path.count < TOSDNSRules.maximumContacts {
            guard seen.insert(current).inserted else { throw TOSDNSError.invalidResponse("resolver cycle") }
            path.append(current)
            let queryCell = try Builder().store(data: remaining).endCell()
            let result = try await runGetter(
                address: current,
                method: "dnsresolve",
                stack: [
                    ["slice", ["bytes": try queryCell.toBoc().base64EncodedString()]],
                    ["num", TOSDNSRules.walletCategory],
                ],
                sequence: sequence
            )
            checkpoint = try bindCheckpoint(result, expected: checkpoint, sequence: sequence)
            let stack = try resultStack(result, count: 2)
            let consumedBits = try stackUInt(stack[0])
            guard consumedBits > 0, consumedBits % 8 == 0, consumedBits <= UInt64(remaining.count * 8) else {
                throw TOSDNSError.invalidResponse("invalid consumed-bit count")
            }
            let consumedBytes = Int(consumedBits / 8)
            guard TOSDNSRules.isComponentBoundary(consumedBytes: consumedBytes, query: remaining) else {
                throw TOSDNSError.invalidResponse("resolver stopped inside a component")
            }
            guard let value = try stackCell(stack[1]) else { throw TOSDNSError.notFound }
            if consumedBytes == remaining.count { terminal = value; break }
            current = try parseAddressRecord(value, expectedTag: 0xBA93, flags: false)
            remaining = remaining.subdata(in: consumedBytes ..< remaining.count)
        }
        guard let record = terminal, let checkpoint else { throw TOSDNSError.invalidResponse("resolver hop limit exhausted") }
        let resolved = try parseAddressRecord(record, expectedTag: 0x9FD3, flags: true)
        guard path.count >= 3 else { throw TOSDNSError.invalidResponse("resolver path lacks a Domain Item") }

        try await verifyItem(item: path[2], collection: path[1], label: label, sequence: sequence, checkpoint: checkpoint)
        let auction = try await runGetter(address: path[2], method: "get_auction_info", stack: [], sequence: sequence)
        _ = try bindCheckpoint(auction, expected: checkpoint, sequence: sequence)
        let auctionStack = try resultStack(auction, count: 3)
        guard try stackUInt(auctionStack[2]) == 0 else { throw TOSDNSError.unsafeLifecycle }
        let fill = try await runGetter(address: path[2], method: "get_last_fill_up_time", stack: [], sequence: sequence)
        _ = try bindCheckpoint(fill, expected: checkpoint, sequence: sequence)
        let lastFill = try stackUInt(try resultStack(fill, count: 1)[0])
        let deadline = try TOSDNSRules.renewalDeadline(lastFillUpTime: lastFill, blockTime: max(observedAt, now))
        return TOSDNSResolutionEvidence(
            canonicalName: name, resolvedAddress: resolved, resolverPath: path,
            masterchainSequence: sequence, rootHash: checkpoint.rootHash, fileHash: checkpoint.fileHash,
            observedAt: observedAt, lastFillUpTime: lastFill, renewalDeadline: deadline
        )
    }

    private func verifyItem(item: String, collection: String, label: String, sequence: UInt64, checkpoint: DNSCheckpoint) async throws {
        let identity = try await runGetter(address: item, method: "get_nft_data", stack: [], sequence: sequence)
        _ = try bindCheckpoint(identity, expected: checkpoint, sequence: sequence)
        let stack = try resultStack(identity, count: 5)
        let index = try stackBigUInt(stack[1])
        guard let collectionCell = try stackCell(stack[2]), try parseBareAddress(collectionCell) == collection else {
            throw TOSDNSError.invalidResponse("Domain Item belongs to another Collection")
        }
        let labelCell = try Builder().store(data: Data(label.utf8)).endCell()
        guard index == BigUInt(labelCell.hash()) else {
            throw TOSDNSError.invalidResponse("Domain Item index differs from its label")
        }
        let derived = try await runGetter(
            address: collection, method: "get_nft_address_by_index",
            stack: [["num", index.description]], sequence: sequence
        )
        _ = try bindCheckpoint(derived, expected: checkpoint, sequence: sequence)
        guard let addressCell = try stackCell(try resultStack(derived, count: 1)[0]),
              try parseBareAddress(addressCell) == item
        else { throw TOSDNSError.invalidResponse("Domain Item address is not canonical") }
    }

    private func runGetter(address: String, method: String, stack: [Any], sequence: UInt64) async throws -> [String: Any] {
        let result = try await call("runGetMethod", ["address": address, "method": method, "stack": stack, "seqno": sequence])
        guard result["@type"] as? String == "smc.runResult", int(result["exit_code"]) == 0 else {
            throw TOSDNSError.invalidResponse("\(method) failed")
        }
        return result
    }

    private func bindCheckpoint(_ result: [String: Any], expected: DNSCheckpoint?, sequence: UInt64) throws -> DNSCheckpoint {
        guard let block = result["block_id"] as? [String: Any], int(block["workchain"]) == -1,
              uint(block["seqno"]) == sequence,
              let root = block["root_hash"] as? String, !root.isEmpty,
              let file = block["file_hash"] as? String, !file.isEmpty
        else { throw TOSDNSError.invalidResponse("getter omitted its full block identity") }
        let checkpoint = DNSCheckpoint(sequence: sequence, rootHash: root, fileHash: file)
        if let expected, expected != checkpoint { throw TOSDNSError.invalidResponse("getter checkpoint changed") }
        return checkpoint
    }

    private func configRoot(_ result: [String: Any]) throws -> String {
        guard result["@type"] as? String == "configInfo", let config = result["config"] as? [String: Any],
              config["@type"] as? String == "tvm.cell", let encoded = config["bytes"] as? String,
              let data = Data(base64Encoded: encoded), let cell = try Cell.fromBoc(src: data).first
        else { throw TOSDNSError.invalidResponse("ConfigParam 4 is missing") }
        let slice = cell.beginParse()
        guard slice.remainingBits == 256, slice.remainingRefs == 0 else {
            throw TOSDNSError.invalidResponse("ConfigParam 4 has an invalid shape")
        }
        let bytes = try slice.loadBits(256).bitsToPaddedBuffer().toByteArray()
        return "-1:" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func resultStack(_ result: [String: Any], count: Int) throws -> [Any] {
        guard let stack = result["stack"] as? [Any], stack.count == count else {
            throw TOSDNSError.invalidResponse("getter returned an unexpected stack")
        }
        return stack
    }

    private func stackPair(_ entry: Any) throws -> (String, Any?) {
        guard let pair = entry as? [Any], pair.count == 1 || pair.count == 2, let kind = pair[0] as? String else {
            throw TOSDNSError.invalidResponse("invalid stack entry")
        }
        return (kind, pair.count == 2 ? pair[1] : nil)
    }

    private func stackBigUInt(_ entry: Any) throws -> BigUInt {
        let (kind, value) = try stackPair(entry)
        guard kind == "num", let text = value as? String,
              let number = text.hasPrefix("0x") ? BigUInt(String(text.dropFirst(2)), radix: 16) : BigUInt(text)
        else { throw TOSDNSError.invalidResponse("stack value is not an unsigned integer") }
        return number
    }

    private func stackUInt(_ entry: Any) throws -> UInt64 {
        let number = try stackBigUInt(entry)
        guard number <= BigUInt(UInt64.max) else { throw TOSDNSError.invalidResponse("stack integer is too large") }
        return UInt64(number)
    }

    private func stackCell(_ entry: Any) throws -> Cell? {
        let (kind, value) = try stackPair(entry)
        if kind == "null" { return nil }
        guard kind == "cell" || kind == "slice", let object = value as? [String: Any],
              let encoded = object["bytes"] as? String, let data = Data(base64Encoded: encoded),
              let cell = try Cell.fromBoc(src: data).first
        else { throw TOSDNSError.invalidResponse("stack value is not a cell") }
        return cell
    }

    private func parseBareAddress(_ cell: Cell) throws -> String {
        let slice = cell.beginParse()
        let address: Address = try slice.loadType()
        guard slice.remainingBits == 0, slice.remainingRefs == 0 else {
            throw TOSDNSError.invalidResponse("address cell has trailing data")
        }
        return address.toRaw()
    }

    private func parseAddressRecord(_ cell: Cell, expectedTag: UInt64, flags: Bool) throws -> String {
        let slice = cell.beginParse()
        guard try slice.loadUint(bits: 16) == expectedTag else {
            throw TOSDNSError.invalidResponse("DNS record type does not match its category")
        }
        let address: Address = try slice.loadType()
        if flags {
            let flag = try slice.loadUint(bits: 8)
            guard flag <= 1 else { throw TOSDNSError.invalidResponse("invalid DNS record flags") }
            if flag == 1 { _ = try slice.loadRef() }
        }
        guard slice.remainingBits == 0, slice.remainingRefs == 0 else {
            throw TOSDNSError.invalidResponse("DNS record has trailing data")
        }
        return address.toRaw()
    }

    private func int(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        return Int64(value as? String ?? "") ?? 0
    }

    private func uint(_ value: Any?) -> UInt64 {
        if let number = value as? NSNumber { return number.uint64Value }
        return UInt64(value as? String ?? "") ?? 0
    }
}

extension API {
    func resolveTOSDomain(_ name: String) async throws -> TOSDNSResolutionEvidence {
        try await TOSDNSResolver { method, params in
            try await tosRPCCall(method: method, params: params)
        }.resolveWallet(name)
    }
}
