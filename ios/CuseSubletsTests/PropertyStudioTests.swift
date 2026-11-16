import XCTest

@testable import CuseSublets

final class PropertyStudioTests: XCTestCase {
  private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("properties.json")
  }

  func testPropertiesPersistNewestFirst() {
    let file = temporaryFile()
    let store = PropertyStore(file: file)
    let first = store.add(name: "  12 Elm St ")
    let second = store.add(name: "")
    store.update(first.id) { $0.uploaded = true }
    let reloaded = PropertyStore(file: file).properties
    XCTAssertEqual(reloaded.map(\.name), ["Untitled property", "12 Elm St"])
    XCTAssertEqual(reloaded.map(\.uploaded), [false, true])
    XCTAssertEqual(second.id, second.id.lowercased())
    XCTAssertNotNil(UUID(uuidString: second.id))
  }

  func testRemovingAPropertyForgetsIt() {
    let file = temporaryFile()
    let store = PropertyStore(file: file)
    let property = store.add(name: "A")
    store.remove(property.id)
    XCTAssertTrue(PropertyStore(file: file).properties.isEmpty)
  }

  func testStudioAddressMustBeAnHttpsOrigin() {
    XCTAssertEqual(
      StudioClient.address(" https://studio.example.net:10445/ ")?.absoluteString,
      "https://studio.example.net:10445")
    XCTAssertEqual(
      StudioClient.address("https://studio.example.net")?.absoluteString,
      "https://studio.example.net")
    for refused in [
      "http://studio.example.net", "studio.example.net", "https://", "https://a.example/path",
      "https://a.example?x=1", "https://user@a.example", "",
    ] {
      XCTAssertNil(StudioClient.address(refused), refused)
    }
  }

  func testRefusalsBecomeReadableMessages() throws {
    let url = URL(string: "https://studio.example.net/api/properties/x")!
    let conflict = HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil, headerFields: nil)!
    XCTAssertThrowsError(
      try StudioClient.check(Data(#"{"error":"already_processing"}"#.utf8), conflict)
    ) { XCTAssertEqual($0 as? StudioFailure, .refused("already_processing")) }
    // A sign-in page or proxy error is not the service answering.
    let page = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
    XCTAssertThrowsError(try StudioClient.check(Data("<html>".utf8), page)) {
      XCTAssertEqual($0 as? StudioFailure, .unreachable)
    }
    let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    XCTAssertEqual(try StudioClient.check(Data("{}".utf8), ok), Data("{}".utf8))
    XCTAssertTrue(StudioClient.explain("spot_incomplete").contains("gaps"))
  }

  func testTokensAreLongLettersAndDigits() {
    XCTAssertTrue(StudioToken.isValid(String(repeating: "a1", count: 16)))
    XCTAssertFalse(StudioToken.isValid(String(repeating: "a", count: 31)))
    XCTAssertFalse(StudioToken.isValid(String(repeating: "a", count: 31) + ";"))
    XCTAssertFalse(StudioToken.isValid(String(repeating: "é", count: 40)))
  }

  func testTokenCookieIsSecureAndScopedToTheService() {
    let client = StudioClient(
      base: URL(string: "https://studio.example.net")!, token: String(repeating: "t", count: 40))
    let cookie = client.tokenCookie
    XCTAssertEqual(cookie?.name, "studio_token")
    XCTAssertEqual(cookie?.domain, "studio.example.net")
    XCTAssertEqual(cookie?.isSecure, true)
    XCTAssertEqual(cookie?.isHTTPOnly, true)
    XCTAssertNil(StudioClient(base: URL(string: "https://studio.example.net")!).tokenCookie)
  }

  func testTourPageIsUnderTheConfiguredOrigin() {
    let client = StudioClient(base: URL(string: "https://studio.example.net:10445")!)
    XCTAssertEqual(
      client.tourPage("abc").absoluteString, "https://studio.example.net:10445/tour/abc")
  }
}
