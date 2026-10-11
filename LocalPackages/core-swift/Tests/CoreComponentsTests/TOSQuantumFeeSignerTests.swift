/* Public test seed and full-tree authentication paths; never use for funds. */
import XCTest
@testable import CoreComponents
final class TOSQuantumFeeSignerTests: XCTestCase {
 func testRealLmsSigningBurnsFailuresAndRetriesExactCache() throws {
  func hex(_ text: String) -> Data {
   var result = [UInt8](); var i = text.startIndex
   while i < text.endIndex { let e = text.index(i, offsetBy: 2); guard let byte = UInt8(text[i..<e], radix: 16) else { XCTFail("bad public fixture"); return Data() }; result.append(byte); i = e }; return Data(result)
  }
  let seed = hex("7015e4db70b1a82cc657f3e45559bc99de99a7dc3d0c2d5b259bbc8d2300275d86eab5e984642406788230273d09951c")
  let key = hex("00000001000000080000000386eab5e984642406788230273d09951c0fa04c5e002df6bb037be303270f754a8d35e0bdee7c108ac525402431dc9005")
  let path4 = hex("b2dcbd54388cdba348372ccba7a5685933722635903e78a31bb21acb178cbd01f3893a80184b89a151c25785abc76424aa6ad353230c2a8d048497e2388990c45a88fb635db4d36f27064a123fea7cb850a6270aa12582d1fbd0eb723f78e13b2dfc1c5f559809177191feb8a03c337d5bd102b0cb626594e62eb6948e2635d9413c162436fe107cc0a02e1cc9236f5483aff37b07650a47edfbf4386c74422d22edf2214600ddb73463e5799f527f66914c6ad9110fdc064d1bc1ef69d3f6a03029d7608d340f27f50a23827153e0449a2fb1989be0b5fe5181cf6ad9536af31c5ca2028de4f77f6dd25dd1cf8e7193724890daa275e0407b830e79141ea4a4e4a371a3c779d4aac2c62c8374408b59763ec004b9896e7bc9ac18149f2f0907d4f5f5bfca024816d76e3470328824d2ceb5326bfbd97ba2d77c06b90be89b75c164f997cc610ff922e66923f23687146260bc9643524d56f094452d6de7bb47ae6e05e513efd1ec2b13900c34b0b3d93bdb9c39cb936cd0dabce267423cdc477b60a0d5a2678f01d67008d7fbd02086ea22467330a90341b987e9796c321be55442140f2e935b8b9e95dd945bef260bd6daa4693323ec32fa6c6094f01658aea398306e3f8b4b5f10df18a459fd6104958d2c12ec5eac583f9565fedacd4f9d5930c06b666aa3efd40bf0db050ce9b7225a3395f9d82080e13c06dc2424dd8b01ad96213985b90ce95708daf5be545f5f3ea97af32fba32d6ab4c9191feb36ca4e7f896af08e2a956352ce872031e8f4e2a0f0be93151ff6b09a96e259863ce0f80c42e840af3d1d90c80d25ed4bbb6ffdc5c0f8717f6eb8f8ac407d3ca6358b9ff4bfef00413a35b67cd467c0debfe952351061d4d288381c819bda252340b")
  let path5 = hex("f018cc300e70245288e27a03a187cd3275c21a3b7676faa64bb45746705a0f4ff3893a80184b89a151c25785abc76424aa6ad353230c2a8d048497e2388990c45a88fb635db4d36f27064a123fea7cb850a6270aa12582d1fbd0eb723f78e13b2dfc1c5f559809177191feb8a03c337d5bd102b0cb626594e62eb6948e2635d9413c162436fe107cc0a02e1cc9236f5483aff37b07650a47edfbf4386c74422d22edf2214600ddb73463e5799f527f66914c6ad9110fdc064d1bc1ef69d3f6a03029d7608d340f27f50a23827153e0449a2fb1989be0b5fe5181cf6ad9536af31c5ca2028de4f77f6dd25dd1cf8e7193724890daa275e0407b830e79141ea4a4e4a371a3c779d4aac2c62c8374408b59763ec004b9896e7bc9ac18149f2f0907d4f5f5bfca024816d76e3470328824d2ceb5326bfbd97ba2d77c06b90be89b75c164f997cc610ff922e66923f23687146260bc9643524d56f094452d6de7bb47ae6e05e513efd1ec2b13900c34b0b3d93bdb9c39cb936cd0dabce267423cdc477b60a0d5a2678f01d67008d7fbd02086ea22467330a90341b987e9796c321be55442140f2e935b8b9e95dd945bef260bd6daa4693323ec32fa6c6094f01658aea398306e3f8b4b5f10df18a459fd6104958d2c12ec5eac583f9565fedacd4f9d5930c06b666aa3efd40bf0db050ce9b7225a3395f9d82080e13c06dc2424dd8b01ad96213985b90ce95708daf5be545f5f3ea97af32fba32d6ab4c9191feb36ca4e7f896af08e2a956352ce872031e8f4e2a0f0be93151ff6b09a96e259863ce0f80c42e840af3d1d90c80d25ed4bbb6ffdc5c0f8717f6eb8f8ac407d3ca6358b9ff4bfef00413a35b67cd467c0debfe952351061d4d288381c819bda252340b")
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: dir) }
  func open(_ time: UInt32) throws -> TOSQuantumFeeState {
   try TOSQuantumFeeState.open(directory: dir, globalID: 42, network: Data(repeating: 1, count: 32), vault: Data(repeating: 2, count: 32), treeID: Data(repeating: 3, count: 32), epoch0: 100, provenTime: time)
  }
  let digest = Data(repeating: 7, count: 32)
  let session = try open(100)
  var input = seed
  let signed = try session.signOnceAndWipe(time: 3700, chainNext: 0, leaf: 4, digest: digest, publicKey: key, seed: &input, path: path4)
  XCTAssertEqual(input, Data(count: 48))
  XCTAssertEqual(try session.cachedVerified(leaf: 4, digest: digest, publicKey: key), signed)
  XCTAssertEqual(try session.preview(time: 3700, chainNext: 0), 5)
  var damaged = path5; damaged[0] ^= 1
  var failed = seed
  XCTAssertThrowsError(try session.signOnceAndWipe(time: 3700, chainNext: 0, leaf: 5, digest: digest, publicKey: key, seed: &failed, path: damaged))
  XCTAssertEqual(failed, Data(count: 48))
  XCTAssertEqual(try session.preview(time: 3700, chainNext: 0), 6)
  var retry = seed
  XCTAssertThrowsError(try session.signOnceAndWipe(time: 3700, chainNext: 0, leaf: 5, digest: digest, publicKey: key, seed: &retry, path: path5))
  try session.close()
  let restored = try open(3700)
  defer { try? restored.close() }
  XCTAssertEqual(try restored.cachedVerified(leaf: 4, digest: digest, publicKey: key), signed)
  XCTAssertThrowsError(try restored.preview(time: 3700, chainNext: 0))
 }
}
