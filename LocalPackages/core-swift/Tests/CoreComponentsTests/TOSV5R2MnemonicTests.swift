import XCTest
@testable import CoreComponents
final class TOSV5R2MnemonicTests: XCTestCase {
 func testNativeMasterVectorsAndPasswordWipe() throws {
  do {
   var password = Data("".utf8)
   let master = try TOSV5R2Mnemonic.masterAndWipePassword(words: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon amateur".split(separator: " ").map(String.init), password: &password)
   XCTAssertEqual(master.map { String(format: "%02x", $0) }.joined(), "cc97dcca0bed763026ad0174ad4c38a057fca97863005b181e11f9f0a0c39bc6")
   XCTAssertEqual(password, Data(count: password.count))
  }
  do {
   var password = Data(" public test password ".utf8)
   let master = try TOSV5R2Mnemonic.masterAndWipePassword(words: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon chicken".split(separator: " ").map(String.init), password: &password)
   XCTAssertEqual(master.map { String(format: "%02x", $0) }.joined(), "5baee244077bdb19c1d9a4670a7c2a3c6dc88815a039eb9c75f3e4d7185f6c39")
   XCTAssertEqual(password, Data(count: password.count))
  }
 }
 func testInvalidPhraseStillWipesPassword() {
  var password = Data("secret".utf8)
  XCTAssertThrowsError(try TOSV5R2Mnemonic.masterAndWipePassword(words: Array(repeating: "abandon", count: 12), password: &password))
  XCTAssertEqual(password, Data(count: 6))
 }
}
