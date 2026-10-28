import Foundation
import TonSwift
import CoreComponents

/// Self-pay v1 codecs. Decoding does not authenticate account or policy state.
public struct TOSQuantumSelfPayAuthority {
    public let globalID: Int32
    public let namespace: Data, primaryKey: Data, rescueKey: Data
    public let policy: TOSQuantumPolicy
    public let cell: Cell
    public var hash: Data { cell.hash() }

    public init(globalID: Int32, namespace: Data, primaryKey: Data, rescueKey: Data,
                policy: TOSQuantumPolicy = .ready) throws {
        guard namespace.count == 32, primaryKey.count == 1312, rescueKey.count == 32 else { throw TOSPQError.invalidInput }
        self.globalID = globalID; self.namespace = namespace
        self.primaryKey = primaryKey; self.rescueKey = rescueKey; self.policy = policy
        cell = try Builder().store(uint: 1, bits: 8).store(int: globalID, bits: 32).store(data: namespace)
            .store(uint: 1, bits: 8).store(ref: TOSPQWallet.byteChain(primaryKey)).store(data: rescueKey)
            .store(uint: policy.rawValue, bits: 8).endCell()
    }

    public static func parse(_ cell: Cell) throws -> Self {
        try ordinary(cell)
        let s = try cell.beginParse()
        guard s.remainingBits == 568, s.remainingRefs == 1, try s.loadUint(bits: 8) == 1 else { throw TOSPQError.invalidInput }
        let globalID = Int32(try s.loadInt(bits: 32)), namespace = try s.loadBytes(32)
        guard try s.loadUint(bits: 8) == 1 else { throw TOSPQError.invalidInput }
        let primaryKey = try bytes(s.loadRef(), length: 1312), rescueKey = try s.loadBytes(32)
        guard let policy = TOSQuantumPolicy(rawValue: UInt8(try s.loadUint(bits: 8))) else { throw TOSPQError.invalidInput }
        return try Self(globalID: globalID, namespace: namespace, primaryKey: primaryKey, rescueKey: rescueKey, policy: policy)
    }

    static func ordinary(_ cell: Cell) throws {
        guard !cell.isExotic, cell.level == 0 else { throw TOSPQError.invalidInput }
    }

    static func bytes(_ root: Cell, length: Int) throws -> Data {
        var result = Data(), current = root
        while true {
            try ordinary(current)
            let s = try current.beginParse(), remaining = length - result.count
            let count = min(127, remaining)
            guard count > 0, s.remainingBits == count * 8,
                  s.remainingRefs == (remaining > 127 ? 1 : 0) else { throw TOSPQError.invalidInput }
            result.append(try s.loadBytes(count))
            if result.count == length { return result }
            current = try s.loadRef()
        }
    }
}

public struct TOSQuantumSelfPayState {
    public let authority: TOSQuantumSelfPayAuthority
    public let walletID: UInt32, seqno: UInt32, retired: UInt16
    public let epoch: UInt64, primaryNonce: UInt64, rescueNonce: UInt64
    public let cell: Cell

    public init(authority: TOSQuantumSelfPayAuthority, walletID: UInt32 = 0, seqno: UInt32 = 0,
                retired: UInt16 = 0, epoch: UInt64 = 0, primaryNonce: UInt64 = 0, rescueNonce: UInt64 = 0) throws {
        guard retired & ~UInt16(2) == 0 else { throw TOSPQError.invalidInput }
        self.authority = authority; self.walletID = walletID; self.seqno = seqno; self.retired = retired
        self.epoch = epoch; self.primaryNonce = primaryNonce; self.rescueNonce = rescueNonce
        cell = try Builder().store(uint: 1, bits: 8).store(uint: seqno, bits: 32).store(uint: walletID, bits: 32)
            .store(uint: retired, bits: 16).store(uint: epoch, bits: 64).store(uint: primaryNonce, bits: 64)
            .store(uint: rescueNonce, bits: 64).store(ref: authority.cell).endCell()
    }

    public static func parse(_ cell: Cell) throws -> Self {
        try TOSQuantumSelfPayAuthority.ordinary(cell)
        let s = try cell.beginParse()
        guard s.remainingBits == 280, s.remainingRefs == 1, try s.loadUint(bits: 8) == 1 else { throw TOSPQError.invalidInput }
        let seqno = UInt32(try s.loadUint(bits: 32)), walletID = UInt32(try s.loadUint(bits: 32))
        let retired = UInt16(try s.loadUint(bits: 16)), epoch = try s.loadUint(bits: 64)
        let primary = try s.loadUint(bits: 64), rescue = try s.loadUint(bits: 64)
        return try Self(authority: TOSQuantumSelfPayAuthority.parse(s.loadRef()), walletID: walletID,
                        seqno: seqno, retired: retired, epoch: epoch, primaryNonce: primary, rescueNonce: rescue)
    }
}

/// Birth identity must remain in backup after same-address key rotation.
public struct TOSQuantumSelfPayWallet {
    public let initialAuthority: TOSQuantumSelfPayAuthority
    public let walletID: UInt32
    public let code: Cell, initialData: Cell, stateInit: Cell
    public let address: Address

    public init(authority: TOSQuantumSelfPayAuthority, walletID: UInt32 = 0) throws {
        initialAuthority = authority; self.walletID = walletID
        code = try TOSQuantumSelfPayCode.wallet()
        initialData = try TOSQuantumSelfPayState(authority: authority, walletID: walletID).cell
        stateInit = try Self.stateInit(code: code, data: initialData)
        address = Address(workchain: 0, hash: stateInit.hash())
    }

    static func stateInit(code: Cell, data: Cell) throws -> Cell {
        try Builder().store(uint: 6, bits: 5).store(ref: code).store(ref: data).endCell()
    }

    public func readState(account: Address, code: Cell, data: Cell) throws -> TOSQuantumSelfPayState {
        guard account == address, code.hash() == self.code.hash() else { throw TOSPQError.keyBinding }
        let state = try TOSQuantumSelfPayState.parse(data)
        guard state.walletID == walletID, state.authority.globalID == initialAuthority.globalID,
              state.authority.namespace == initialAuthority.namespace else { throw TOSPQError.keyBinding }
        return state
    }

    public func external(body: Cell, deploy: Bool) throws -> Cell {
        let b = try Builder().store(uint: 8, bits: 4).store(address).store(uint: 0, bits: 4).store(bit: deploy)
        if deploy { try b.store(bit: true).store(ref: stateInit) }
        return try b.store(bit: true).store(ref: body).endCell()
    }
}

public enum TOSQuantumSelfPayAction {
    case execute(Cell)
    case configureRequired
    case lockPrimary
    case migrate(TOSQuantumSelfPayAuthority)
}

/// Caller authenticates state and any CP48 at the same fresh checkpoint.
/// PRIMARY execution and RESCUE migration to READY both require eligible CP48.
/// A raw policy cell is structurally checked here, but is not a proof capability.
public struct TOSQuantumSelfPayRequest {
    public let request: Cell
    public let role: TOSQuantumRole
    public let wallet: Address
    public let globalID: Int32
    public let namespace: Data
    public let signingPublicKey: Data
    public var digest: Data { request.hash() }
    public var context: String { role == .primary ? "TOS-QSP-MLDSA44-v1" : "TOS-QSP-SLH128S-v1" }

    public init(wallet: Address, state: TOSQuantumSelfPayState, role: TOSQuantumRole,
                validUntil: UInt32, action: TOSQuantumSelfPayAction, provenTime: UInt32, primaryPolicy: Cell? = nil) throws {
        guard wallet.workchain == 0, validUntil > provenTime,
              UInt64(validUntil) - UInt64(provenTime) <= 3600 else { throw TOSPQError.invalidInput }
        let nonce = role == .primary ? state.primaryNonce : state.rescueNonce
        let kind: UInt8, payload: Cell
        switch action {
        case .execute(let actions):
            guard state.seqno < UInt32.max, nonce < UInt64.max else { throw TOSPQError.invalidInput }
            try TOSQuantumAuth.validateActions(actions)
            kind = 0; payload = try Builder().store(uint: 0x45584543, bits: 32).store(ref: actions).endCell()
        case .configureRequired:
            guard state.seqno < UInt32.max else { throw TOSPQError.invalidInput }
            kind = 1; payload = try Builder().store(uint: 0x434f4e46, bits: 32).store(uint: 2, bits: 2).endCell()
        case .lockPrimary:
            kind = 3; payload = try Builder().store(uint: 0x4c4f434b, bits: 32).store(uint: 1, bits: 8).endCell()
        case .migrate(let successor):
            guard successor.globalID == state.authority.globalID, successor.namespace == state.authority.namespace,
                  state.retired == 0 || successor.policy == .required else { throw TOSPQError.invalidInput }
            kind = 4; payload = try Builder().store(uint: 0x4d494752, bits: 32).store(ref: successor.cell).endCell()
        }
        if role == .primary {
            guard kind == 0, state.retired == 0, state.authority.policy == .ready else { throw TOSPQError.invalidInput }
        }
        if kind != 0 { guard role == .rescue, state.epoch < UInt64.max else { throw TOSPQError.invalidInput } }
        let migratingToReady: Bool
        if case .migrate(let successor) = action { migratingToReady = successor.policy == .ready }
        else { migratingToReady = false }
        if role == .primary || migratingToReady {
            guard let primaryPolicy else { throw TOSPQError.invalidInput }
            try TOSQuantumRetirementPolicy.requirePrimary(primaryPolicy, network: state.authority.namespace, now: provenTime)
        }
        self.role = role
        self.wallet = wallet
        self.globalID = state.authority.globalID
        self.namespace = state.authority.namespace
        self.signingPublicKey = role == .primary ? state.authority.primaryKey : state.authority.rescueKey
        request = try Builder().store(uint: 0x51535031, bits: 32).store(int: state.authority.globalID, bits: 32)
            .store(data: state.authority.namespace).store(wallet).store(data: state.authority.hash)
            .store(uint: role.rawValue, bits: 8).store(uint: state.epoch, bits: 64).store(uint: nonce, bits: 64)
            .store(uint: validUntil, bits: 32).store(uint: kind, bits: 8).store(ref: payload).endCell()
    }

    public func submission(signature: Data) throws -> Cell {
        guard signature.count == role.signatureSize else { throw TOSPQError.invalidInput }
        return try Builder().store(ref: request).store(ref: TOSPQWallet.byteChain(signature)).endCell()
    }
}

/// Authenticate the account before checking this receipt. Getters are insufficient.
public struct TOSQuantumSelfPayProbe {
    public let code: Cell, immutable: Cell, initialData: Cell, stateInit: Cell
    public let address: Address
    public var digest: Data {
        get throws { try Builder().store(uint: 0x51505031, bits: 32).store(data: code.hash()).store(ref: immutable).endCell().hash() }
    }

    public init(wallet: Address, authority: TOSQuantumSelfPayAuthority, challenge: Data,
                validUntil: UInt32, provenTime: UInt32) throws {
        guard wallet.workchain == 0, challenge.count == 32, challenge.contains(where: { $0 != 0 }),
              validUntil > provenTime, UInt64(validUntil) - UInt64(provenTime) <= 3600 else { throw TOSPQError.invalidInput }
        code = try TOSQuantumSelfPayCode.probe()
        immutable = try Builder().store(uint: 0x51505031, bits: 32).store(int: authority.globalID, bits: 32)
            .store(data: authority.namespace).store(wallet).store(data: challenge).store(uint: validUntil, bits: 32)
            .store(ref: authority.cell).endCell()
        initialData = try Builder().store(uint: 1, bits: 8).store(bit: false).store(ref: immutable).endCell()
        stateInit = try TOSQuantumSelfPayWallet.stateInit(code: code, data: initialData)
        address = Address(workchain: 0, hash: stateInit.hash())
    }

    public func submission(primarySignature: Data, rescueSignature: Data) throws -> Cell {
        guard primarySignature.count == 2420, rescueSignature.count == 7856 else { throw TOSPQError.invalidInput }
        return try Builder().store(ref: TOSPQWallet.byteChain(primarySignature))
            .store(ref: TOSPQWallet.byteChain(rescueSignature)).endCell()
    }

    public func requireVerified(account: Address, installedCode: Cell, installedData: Cell) throws {
        guard account == address, installedCode.hash() == code.hash() else { throw TOSPQError.keyBinding }
        try TOSQuantumSelfPayAuthority.ordinary(installedData)
        let s = try installedData.beginParse()
        guard s.remainingBits == 9, s.remainingRefs == 1, try s.loadUint(bits: 8) == 1,
              try s.loadBoolean(), try s.loadRef().hash() == immutable.hash() else { throw TOSPQError.keyBinding }
    }
}
