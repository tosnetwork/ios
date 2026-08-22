import BigInt
import Foundation
import TonSwift

/// Canonical TIP-1 message bodies for the inherited DNS Collection/Item ABI.
///
/// This type deliberately contains no lifecycle guesses. Callers must obtain a
/// checkpoint-bound Domain Item/Collection address and validate the intended
/// action before presenting the wallet confirmation.
public enum TOSDNSOperation: Equatable {
    public static let getStaticDataOpcode: UInt64 = 0x2fcb26a2
    public static let changeRecordOpcode: UInt64 = 0x4eb1f0f9
    public static let balanceReleaseOpcode: UInt64 = 0x4ed14b65

    case register(label: String)
    case bidOrTopUp
    case finishAuction(queryId: UInt64)
    case changeRecord(category: BigUInt, value: Cell?, queryId: UInt64)
    case release(queryId: UInt64)

    public func body() throws -> Cell {
        switch self {
        case let .register(label):
            try Self.validateRegistrationLabel(label)
            let bytes = Data(label.utf8)
            let headCount = min(bytes.count, 123)
            let builder = try Builder()
                .store(uint: 0, bits: 32)
                .store(data: Data(bytes.prefix(headCount)))
            if headCount < bytes.count {
                try builder.store(ref: Builder().store(data: Data(bytes.dropFirst(headCount))).endCell())
            }
            return try builder.endCell()
        case .bidOrTopUp:
            return .empty
        case let .finishAuction(queryId):
            return try Builder()
                .store(uint: Self.getStaticDataOpcode, bits: 32)
                .store(uint: queryId, bits: 64)
                .endCell()
        case let .changeRecord(category, value, queryId):
            guard category.bitWidth <= 256 else { throw TOSDNSOperationError.categoryTooLarge }
            let builder = try Builder()
                .store(uint: Self.changeRecordOpcode, bits: 32)
                .store(uint: queryId, bits: 64)
                .store(uint: category, bits: 256)
            if let value {
                try builder.store(ref: value)
            }
            return try builder.endCell()
        case let .release(queryId):
            return try Builder()
                .store(uint: Self.balanceReleaseOpcode, bits: 32)
                .store(uint: queryId, bits: 64)
                .endCell()
        }
    }

    private static func validateRegistrationLabel(_ label: String) throws {
        let bytes = Array(label.utf8)
        guard bytes.count >= 4, bytes.count <= 126 else {
            throw TOSDNSOperationError.invalidRegistrationLabel
        }
        guard bytes.first != 0x2d, bytes.last != 0x2d,
              bytes.allSatisfy({ $0 >= 0x61 && $0 <= 0x7a || $0 >= 0x30 && $0 <= 0x39 || $0 == 0x2d })
        else { throw TOSDNSOperationError.invalidRegistrationLabel }
    }
}

public enum TOSDNSOperationError: LocalizedError, Equatable {
    case invalidRegistrationLabel
    case categoryTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidRegistrationLabel:
            "A registration label must be 4–126 lowercase ASCII letters, digits, or interior hyphens."
        case .categoryTooLarge:
            "A DNS record category must fit in 256 bits."
        }
    }
}

public enum TOSDNSLifecycle: Equatable {
    case available
    case auction
    case auctionEnded
    case leased
    case releasable
}

public struct TOSDNSDomainState: Equatable {
    public let canonicalName: String
    public let label: String
    public let rootAddress: Address
    public let collectionAddress: Address
    public let itemAddress: Address
    public let lifecycle: TOSDNSLifecycle
    public let ownerAddress: Address?
    public let maximumBid: BigUInt
    public let auctionEndTime: UInt64
    public let renewalDeadline: UInt64?
    public let masterchainSequence: UInt64
    public let checkpointRootHash: String
    public let checkpointFileHash: String
    public let observedAt: UInt64

    public init(
        canonicalName: String,
        label: String,
        rootAddress: Address,
        collectionAddress: Address,
        itemAddress: Address,
        lifecycle: TOSDNSLifecycle,
        ownerAddress: Address?,
        maximumBid: BigUInt,
        auctionEndTime: UInt64,
        renewalDeadline: UInt64?,
        masterchainSequence: UInt64 = 0,
        checkpointRootHash: String = "",
        checkpointFileHash: String = "",
        observedAt: UInt64 = 0
    ) {
        self.canonicalName = canonicalName
        self.label = label
        self.rootAddress = rootAddress
        self.collectionAddress = collectionAddress
        self.itemAddress = itemAddress
        self.lifecycle = lifecycle
        self.ownerAddress = ownerAddress
        self.maximumBid = maximumBid
        self.auctionEndTime = auctionEndTime
        self.renewalDeadline = renewalDeadline
        self.masterchainSequence = masterchainSequence
        self.checkpointRootHash = checkpointRootHash
        self.checkpointFileHash = checkpointFileHash
        self.observedAt = observedAt
    }
}

public enum TOSDNSAuctionRules {
    public static let auctionStartTime: UInt64 = 1_798_761_600
    public static let periodSeconds: UInt64 = 2_592_000
    public static let leaseSeconds: UInt64 = 31_622_400
    public static let oneTOS = BigUInt(1_000_000_000)
    public static let contractActionValue = BigUInt(100_000_000)

    public static func minimumNextBid(_ current: BigUInt) -> BigUInt {
        current * 105 / 100
    }

    public static func minimumPrice(labelBytes: Int, now: UInt64) throws -> BigUInt {
        guard (4 ... 126).contains(labelBytes) else { throw TOSDNSOperationError.invalidRegistrationLabel }
        let tier: (UInt64, UInt64) = switch labelBytes {
        case 4: (1_000, 100)
        case 5: (500, 50)
        case 6: (400, 40)
        case 7: (300, 30)
        case 8: (200, 20)
        case 9: (100, 10)
        case 10: (50, 5)
        default: (10, 1)
        }
        var value = BigUInt(tier.0) * oneTOS
        let floor = BigUInt(tier.1) * oneTOS
        let periods = now > auctionStartTime ? (now - auctionStartTime) / periodSeconds : 0
        if periods > 21 { return floor }
        for _ in 0 ..< periods { value = value * 90 / 100 }
        return value
    }
}

public enum TOSDNSManagementAction: Equatable {
    case register(bid: BigUInt)
    case bid(amount: BigUInt)
    case finishAuction
    case renew(amount: BigUInt)
    case release(bid: BigUInt)
    case changeRecord(category: BigUInt, value: Cell?)
}

public enum TOSDNSManagementPlanner {
    public static func operation(
        state: TOSDNSDomainState,
        walletAddress: Address,
        action: TOSDNSManagementAction,
        now: UInt64,
        queryId: UInt64
    ) throws -> TransferData.DomainOperation {
        switch action {
        case let .register(bid):
            guard state.lifecycle == .available, now > TOSDNSAuctionRules.auctionStartTime,
                  bid >= (try TOSDNSAuctionRules.minimumPrice(labelBytes: state.label.utf8.count, now: now))
            else { throw TOSDNSManagementError.actionNotAllowed }
            return .init(target: state.collectionAddress, amount: bid, operation: .register(label: state.label))
        case let .bid(amount):
            guard state.lifecycle == .auction, amount >= TOSDNSAuctionRules.minimumNextBid(state.maximumBid)
            else { throw TOSDNSManagementError.actionNotAllowed }
            return .init(target: state.itemAddress, amount: amount, operation: .bidOrTopUp)
        case .finishAuction:
            guard state.lifecycle == .auctionEnded else { throw TOSDNSManagementError.actionNotAllowed }
            return .init(
                target: state.itemAddress,
                amount: TOSDNSAuctionRules.contractActionValue,
                operation: .finishAuction(queryId: queryId)
            )
        case let .renew(amount):
            guard state.lifecycle == .leased, state.ownerAddress == walletAddress,
                  amount >= TOSDNSAuctionRules.oneTOS
            else { throw TOSDNSManagementError.actionNotAllowed }
            return .init(target: state.itemAddress, amount: amount, operation: .bidOrTopUp)
        case let .release(bid):
            guard state.lifecycle == .releasable,
                  bid >= (try TOSDNSAuctionRules.minimumPrice(labelBytes: state.label.utf8.count, now: now))
            else { throw TOSDNSManagementError.actionNotAllowed }
            return .init(target: state.itemAddress, amount: bid, operation: .release(queryId: queryId))
        case let .changeRecord(category, value):
            guard state.lifecycle == .leased, state.ownerAddress == walletAddress
            else { throw TOSDNSManagementError.actionNotAllowed }
            return .init(
                target: state.itemAddress,
                amount: TOSDNSAuctionRules.contractActionValue,
                operation: .changeRecord(category: category, value: value, queryId: queryId)
            )
        }
    }
}

public enum TOSDNSManagementError: LocalizedError, Equatable {
    case actionNotAllowed

    public var errorDescription: String? {
        "The requested DNS action does not match the latest owner, auction, or renewal state."
    }
}

public struct TOSDNSOperationTransferBuilder {
    private init() {}

    public static func createWalletTransfer(
        wallet: Wallet,
        seqno: UInt64,
        target: Address,
        amount: BigUInt,
        operation: TOSDNSOperation,
        timeout: UInt64?,
        messageType: MessageType
    ) throws -> WalletTransfer {
        let body = try operation.body()
        return try WalletTransferBuilder.buildWalletTransfer(
            wallet: wallet,
            sender: wallet.address,
            seqno: seqno,
            internalMessages: { _ in
                [MessageRelaxed.internal(to: target, value: amount, bounce: true, body: body)]
            },
            timeout: timeout,
            messageType: messageType
        )
    }
}
