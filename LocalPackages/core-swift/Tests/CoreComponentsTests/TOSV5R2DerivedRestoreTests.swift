/* Public frozen master/material only; never use for funds. */
import XCTest
@testable import CoreComponents
final class TOSV5R2DerivedRestoreTests: XCTestCase {
 private func hex(_ text: String) -> Data {
  var result = [UInt8](); var i = text.startIndex
  while i < text.endIndex { let e = text.index(i, offsetBy: 2); guard let b = UInt8(text[i..<e], radix: 16) else { XCTFail("bad public fixture"); return Data() }; result.append(b); i = e }; return Data(result)
 }
 func testDerivedRolesBindEnrollmentAndClearMaster() throws {
  let context = try TOSV5R2SeedKeychain.Context(network: hex("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"), globalID: -239, account: 0, generation: 0)
  do {
   let material = hex("7e818ac507abf0c92d98bb1fe1cde59af6b050fe3c7a44544084c4852b82d455")
   let expected = try TOSV5R2Signer.publicKey(role: .primary, seed: material)
   var master = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
   var seed = try TOSV5R2SeedKeychain.deriveBoundAndWipe(role: .primary, context: context, master: &master,
       inputProfile: .rawMaster32, declaredProfile: .rawMaster32, expectedPublicKey: expected)
   XCTAssertEqual(seed, material); XCTAssertEqual(master, Data(count: 32))
   seed.resetBytes(in: 0..<seed.count)
   var bad = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
   var wrong = expected; wrong[0] ^= 1
   XCTAssertThrowsError(try TOSV5R2SeedKeychain.deriveBoundAndWipe(role: .primary, context: context, master: &bad,
       inputProfile: .rawMaster32, declaredProfile: .rawMaster32, expectedPublicKey: wrong))
   XCTAssertEqual(bad, Data(count: 32))
   var mismatch = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
   XCTAssertThrowsError(try TOSV5R2SeedKeychain.deriveBoundAndWipe(role: .primary, context: context, master: &mismatch,
       inputProfile: .rawMaster32, declaredProfile: .nativeMnemonic, expectedPublicKey: expected))
   XCTAssertEqual(mismatch, Data(count: 32))
  }
  do {
   let material = hex("6a722ced6bb6a327db70e5c4ee35f2cb5fcb53dd60fbf56fc724595c6564a6ca7d9e63457ac0bad4adb0ee44977e442c")
   let expected = try TOSV5R2Signer.publicKey(role: .rescue, seed: material)
   var master = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
   var seed = try TOSV5R2SeedKeychain.deriveBoundAndWipe(role: .rescue, context: context, master: &master,
       inputProfile: .rawMaster32, declaredProfile: .rawMaster32, expectedPublicKey: expected)
   XCTAssertEqual(seed, material); XCTAssertEqual(master, Data(count: 32))
   seed.resetBytes(in: 0..<seed.count)
   var bad = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
   var wrong = expected; wrong[0] ^= 1
   XCTAssertThrowsError(try TOSV5R2SeedKeychain.deriveBoundAndWipe(role: .rescue, context: context, master: &bad,
       inputProfile: .rawMaster32, declaredProfile: .rawMaster32, expectedPublicKey: wrong))
   XCTAssertEqual(bad, Data(count: 32))
   var mismatch = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
   XCTAssertThrowsError(try TOSV5R2SeedKeychain.deriveBoundAndWipe(role: .rescue, context: context, master: &mismatch,
       inputProfile: .rawMaster32, declaredProfile: .nativeMnemonic, expectedPublicKey: expected))
   XCTAssertEqual(mismatch, Data(count: 32))
  }
 }
}
