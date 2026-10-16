import XCTest

@testable import CuseSublets

final class ModelsTests: XCTestCase {
  func testSessionKeychainRoundTrip() throws {
    let vault = KeychainSession(account: "isolated-unit-test-" + UUID().uuidString)
    defer { try? vault.save(nil) }
    try vault.save(
      SessionCredential(cookie: "synthetic-session=value", expires: Date().addingTimeInterval(60)))
    XCTAssertEqual(vault.read()?.cookie, "synthetic-session=value")
    try vault.save(nil)
    XCTAssertNil(vault.read())
  }
  func testRoomLayoutPreservesColumnMajorTransform() throws {
    let matrix: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3, 2, 1, 1]
    let original = RoomLayout(elements: [
      .init(kind: "wall", dimensions: [4, 2.5, 0], transform: matrix)
    ])
    let copy = try JSONDecoder().decode(RoomLayout.self, from: JSONEncoder().encode(original))
    XCTAssertEqual(copy.elements[0].transform[12], 3)
    XCTAssertEqual(copy.elements[0].dimensions[1], 2.5)
  }
  func testPublicSessionDoesNotRequireAccount() throws {
    let data = Data(#"{"user":null,"demo":false,"staging":true}"#.utf8)
    XCTAssertNil(try JSONDecoder().decode(SessionResponse.self, from: data).user)
  }
  func testDraftAcceptsIncompleteWebForm() throws {
    let data = Data(
      #"{"draft":{"id":"search","kind":"search","revision":2,"data":{"maxBudget":"950","activate":false,"areas":[]}},"revision":2}"#
        .utf8)
    let result = try JSONDecoder().decode(DraftResponse.self, from: data)
    XCTAssertEqual(result.draft?.data["maxBudget"]?.value as? String, "950")
    XCTAssertEqual(result.draft?.data["activate"]?.value as? Bool, false)
  }
  func testSyracuseDateDoesNotUseDeviceTimeZone() {
    let date = Date(timeIntervalSince1970: 1_792_116_000)
    let expected = isoDay(date)
    let originalZone = NSTimeZone.default
    defer { NSTimeZone.default = originalZone }
    NSTimeZone.default = TimeZone(secondsFromGMT: 12 * 3600)!
    XCTAssertEqual(isoDay(date), expected)
  }
}
