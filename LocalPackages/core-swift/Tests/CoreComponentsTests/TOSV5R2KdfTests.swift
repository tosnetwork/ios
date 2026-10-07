import XCTest
@testable import CoreComponents
final class TOSV5R2KdfTests: XCTestCase {
 private func hex(_ text: String) -> Data {
  var bytes = [UInt8](); var i = text.startIndex
  while i < text.endIndex { let e = text.index(i, offsetBy: 2); guard let b = UInt8(text[i..<e], radix: 16) else { XCTFail("invalid fixture"); return Data() }; bytes.append(b); i = e }; return Data(bytes)
 }
 func testFrozenDerivationsAndMasterWipe() throws {
  do {
   var master = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
   let actual = try TOSV5R2Kdf.deriveAndWipe(material: .primary, master: &master, network: hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"), globalID: -239, account: 0, generation: 0, treeID: nil)
   XCTAssertEqual(actual, hex("7e818ac507abf0c92d98bb1fe1cde59af6b050fe3c7a44544084c4852b82d455")); XCTAssertEqual(master, Data(count: 32))
  }
  do {
   var master = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
   let actual = try TOSV5R2Kdf.deriveAndWipe(material: .rescue, master: &master, network: hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"), globalID: -239, account: 0, generation: 0, treeID: nil)
   XCTAssertEqual(actual, hex("6a722ced6bb6a327db70e5c4ee35f2cb5fcb53dd60fbf56fc724595c6564a6ca7d9e63457ac0bad4adb0ee44977e442c")); XCTAssertEqual(master, Data(count: 32))
  }
  do {
   var master = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
   let actual = try TOSV5R2Kdf.deriveAndWipe(material: .primary, master: &master, network: hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"), globalID: -239, account: 1, generation: 1, treeID: nil)
   XCTAssertEqual(actual, hex("a6e88bc3532b29ccb4cd2ee6b4bbca1fab3344051876f34f90e4e59ddf99a16d")); XCTAssertEqual(master, Data(count: 32))
  }
  do {
   var master = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
   let actual = try TOSV5R2Kdf.deriveAndWipe(material: .rescue, master: &master, network: hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"), globalID: -239, account: 1, generation: 1, treeID: nil)
   XCTAssertEqual(actual, hex("6645b7ee6340ed3efe5392a8388dfcbda20514497449471eff81901fbf23e01d6a2e02909c4e1cf6106367f1eac94691")); XCTAssertEqual(master, Data(count: 32))
  }
  do {
   var master = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
   let actual = try TOSV5R2Kdf.deriveAndWipe(material: .fee, master: &master, network: hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"), globalID: -239, account: 0, generation: 0, treeID: hex("a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5"))
   XCTAssertEqual(actual, hex("5169cfdc6dac3befe15b3204d98c5bc6b26458ff10d342890ea5cbfd4befcedf29816078a9bdffedf4036e0558c3c687")); XCTAssertEqual(master, Data(count: 32))
  }
  do {
   var master = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
   let actual = try TOSV5R2Kdf.deriveAndWipe(material: .fee, master: &master, network: hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"), globalID: -239, account: 0, generation: 0, treeID: hex("a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6"))
   XCTAssertEqual(actual, hex("ac999fa55ec443415e17f5e016fb6b6e4f0b0ea25b8ab89768e379f1ab09c60d70cecdb284835eb86839568c9de2f026")); XCTAssertEqual(master, Data(count: 32))
  }
  do {
   var master = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
   let actual = try TOSV5R2Kdf.deriveAndWipe(material: .fee, master: &master, network: hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"), globalID: -239, account: 1, generation: 1, treeID: hex("a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5"))
   XCTAssertEqual(actual, hex("6606477fc18461092b93eed4bfbc67e149209062d8d479aa760a7a84e57d3bac8f78c93be70cb56b446a82b43665de20")); XCTAssertEqual(master, Data(count: 32))
  }
 }
 func testInvalidContextStillWipesMaster() {
  var master = Data(repeating: 9, count: 32)
  XCTAssertThrowsError(try TOSV5R2Kdf.deriveAndWipe(material: .fee, master: &master, network: Data(count: 32), globalID: 42, account: 0, generation: 0))
  XCTAssertEqual(master, Data(count: 32))
 }
}
