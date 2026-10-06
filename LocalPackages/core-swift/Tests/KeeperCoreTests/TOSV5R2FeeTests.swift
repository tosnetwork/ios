import XCTest
import Foundation
import BigInt
import TonSwift
import CoreComponents
@testable import KeeperCore

final class TOSV5R2FeeTests: XCTestCase {
    private func hash(_ n: UInt8) -> Data { var d=Data(count:32);d[31]=n;return d }
    private func byte(_ n: UInt8) throws -> Cell { try Builder().store(uint:n,bits:8).endCell() }
    private func binding() -> TOSV5R2RecoveryBinding { TOSV5R2RecoveryBinding(globalId:42,network:hash(123),wallet:Address(workchain:0,hash:hash(100)),module:Address(workchain:0,hash:hash(101)),validUntil:1780000600) }
    private func payload(_ kind:TOSV5R2FeeClass,role:TOSV5R2Role = .rescue) throws -> Cell {
        let sig=Data(repeating:0xa5,count:role.signatureSize)
        switch kind {
        case .rescueAuth: return try TOSV5R2Auth(globalId:42,network:hash(123),wallet:Address(workchain:0,hash:hash(100)),module:Address(workchain:0,hash:hash(101)),role:role,epoch:1,nonce:0,validUntil:1780000600,action:.execute(Builder().endCell()),provenTime:1780000000).submission(signature:sig)
        case .pop: return try TOSV5R2Pop(binding:binding(),role:role,policy:.required,primaryKeyChainHash:hash(111),rescueKey:hash(222),challenge:hash(99),provenTime:1780000000).submission(signature:sig)
        case .prepare: return try TOSV5R2Preparation(binding:binding(),moduleAmount:10000000000,vaultAmount:20000000000,moduleInit:byte(1),metadata:byte(2),vaultInit:byte(3),provenTime:1780000000).submission(signature:sig)
        }
    }
    private func fee(_ kind:TOSV5R2FeeClass = .rescueAuth,leaf:UInt32 = 8,value:BigUInt = 5000000000,body:Cell? = nil) throws -> TOSV5R2Fee {
        try TOSV5R2Fee(vault:Address(workchain:0,hash:hash(103)),configHash:hash(104),epoch0:1779992790,leaf:leaf,validUntil:1780000600,value:value,kind:kind,payload:body ?? payload(kind),provenTime:1780000000)
    }
    private func signature() -> Data {
        var d=Data(repeating:0xa5,count:2832)
        for (offset,word) in [(0,UInt32(0)),(4,8),(8,3),(2188,8)] {
            for i in 0..<4 { d[offset+i]=UInt8((word >> (24-i*8)) & 255) }
        };return d
    }
    private let vectors:[[String:String]] = [
        ["kind": "1", "value": "5000000000", "intent_hash": "e1d2c40975d7b824f33062d1a166e453de7a84f541a97c228e000ec18cc9c075", "external_hash": "05a8cd77f02a4b55ab53882b162eab8270d4a98005be40a18405bce8bcf71d27"],
        ["kind": "2", "value": "5000000000", "intent_hash": "8f0e0a5b54bf5f997a3a24cfbfeb390c0589fce720a16710530cbcbdf8b4ec22", "external_hash": "1726c16e2c56e2f2c8ba20d82396cff26bca6a4c8d2707a8de6602a106ee81b0"],
        ["kind": "3", "value": "50000000000", "intent_hash": "251b8014846d093933d0ae64aee6ee21b372980eb5244602a99f45fde98e103b", "external_hash": "7df780a59d41753d319f2169991cfe07ac54423ae9cfd01e2dcd9ecbf7e637a2"],
        ["kind": "1", "value": "1329227995784915872903807060280344575", "intent_hash": "f6b8569c230c5cee555017eb6cfa4e43b172610f47922e961678f5736f4e9548", "external_hash": "97d97ab60ff1249bea87570bf6bf524a53649c772aa9f5e9e7f40aafc4c8aa20"]
    ]
    func testAllIndependentIntentExternalAndSlicedSignatureVectors() throws {
        for v in vectors {
            let kind=try XCTUnwrap(TOSV5R2FeeClass(rawValue:try XCTUnwrap(UInt8(try XCTUnwrap(v["kind"])))))
            let r=try fee(kind,value:try XCTUnwrap(BigUInt(try XCTUnwrap(v["value"]))))
            XCTAssertEqual(r.digest,Data(hex:try XCTUnwrap(v["intent_hash"])))
            let expected: Data = Data(hex:try XCTUnwrap(v["external_hash"]))
            XCTAssertEqual(try r.external(signature:signature()).hash(),expected)
            let padded=Data([9,9])+signature()
            XCTAssertEqual(try r.external(signature:padded.dropFirst(2)).hash(),expected)
            var chain=try r.external(signature:signature()).refs[1];var count=1
            while !chain.refs.isEmpty { XCTAssertEqual(chain.bits.length,1016);chain=chain.refs[0];count+=1 }
            XCTAssertEqual(count,23);XCTAssertEqual(chain.bits.length,304)
        }
    }
    func testPrimaryFeeAuthAndClassAliasesRefused() throws {
        XCTAssertThrowsError(try fee(body:payload(.rescueAuth,role:.primary)))
        for kind in [TOSV5R2FeeClass.rescueAuth,.pop,.prepare] {
            for other in [TOSV5R2FeeClass.rescueAuth,.pop,.prepare] where kind != other { XCTAssertThrowsError(try fee(kind,body:payload(other))) }
        }
        XCTAssertNoThrow(try fee(.pop,body:payload(.pop,role:.primary)))
    }
    func testSlotTerminalLeafSignatureProfileAndAmountsRefused() throws {
        for leaf in [UInt32(4),UInt32(7),UInt32(12),UInt32(1)<<20] { XCTAssertThrowsError(try fee(leaf:leaf)) }
        for value in [BigUInt(0),BigUInt(1)<<120] { XCTAssertThrowsError(try fee(value:value)) }
        let r=try fee()
        for offset in [0,4,8,2188] { var s=signature();s[offset+3]=99;XCTAssertThrowsError(try r.external(signature:s)) }
        for count in [64,2831,2833] { XCTAssertThrowsError(try r.external(signature:Data(count:count))) }
    }
}
