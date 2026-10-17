import AuthenticationServices
import XCTest

@testable import CuseSublets

final class SessionProtocol: URLProtocol {
  static var handler: ((URLRequest) -> (Int, Data))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let result = Self.handler?(request) else { return }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: result.0, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: result.1)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
final class SessionLifecycleTests: XCTestCase {
  @MainActor func testExpiredCredentialEndsSessionBeforeSendingPrivateRequest() async throws {
    let base = URL(string: "https://expired-\(UUID().uuidString).example.test")!
    let vault = KeychainSession(account: base.absoluteString)
    try vault.save(
      SessionCredential(
        cookie: "cuse_password_session=synthetic", expires: Date().addingTimeInterval(60)))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionProtocol.self]
    var time = Date()
    let api = APIClient(baseURL: base, configuration: configuration, now: { time })
    var ended = false
    api.onSessionEnded = { ended = true }
    var sent = false
    SessionProtocol.handler = { _ in
      sent = true
      return (200, Data("{}".utf8))
    }
    defer {
      try? api.clearSession()
      SessionProtocol.handler = nil
    }
    time = time.addingTimeInterval(120)
    do {
      let _: EmptyResponse = try await api.get("/api/mine")
      XCTFail("Expired credential must reject the private operation")
    } catch {}
    XCTAssertTrue(ended)
    XCTAssertFalse(sent)
    XCTAssertNil(vault.read())
  }
  @MainActor func testUnauthorizedResponseClearsCredentialAndPrivateDownloads() async throws {
    let base = URL(string: "https://revoked-\(UUID().uuidString).example.test")!
    let vault = KeychainSession(account: base.absoluteString)
    try vault.save(
      SessionCredential(
        cookie: "cuse_password_session=synthetic", expires: Date().addingTimeInterval(60)))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionProtocol.self]
    let api = APIClient(baseURL: base, configuration: configuration)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cuse-downloads")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("private".utf8).write(to: folder.appendingPathComponent("test"))
    var ended = false
    api.onSessionEnded = { ended = true }
    SessionProtocol.handler = { _ in (401, Data("{\"error\":\"Sign in required\"}".utf8)) }
    defer {
      try? api.clearSession()
      SessionProtocol.handler = nil
    }
    do {
      let _: EmptyResponse = try await api.get("/api/mine")
      XCTFail("Revoked session must be rejected")
    } catch {}
    XCTAssertTrue(ended)
    XCTAssertNil(vault.read())
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
  }
  @MainActor func testColdLaunchWithoutValidCredentialRemovesPrivateDownloads() throws {
    let base = URL(string: "https://cold-\(UUID().uuidString).example.test")!
    let vault = KeychainSession(account: base.absoluteString)
    try vault.save(SessionCredential(cookie: "expired", expires: Date().addingTimeInterval(-60)))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cuse-downloads")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("private".utf8).write(to: folder.appendingPathComponent("test"))
    let api = APIClient(baseURL: base)
    XCTAssertFalse(api.hasStoredSession)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    XCTAssertNil(vault.read())
  }
  @MainActor func testAppleProviderFailureStillChecksServerAndLocalExpiry() async throws {
    let base = URL(string: "https://apple-offline-\(UUID().uuidString).example.test")!
    let vault = KeychainSession(account: base.absoluteString)
    try vault.save(
      SessionCredential(
        cookie: "synthetic", expires: Date().addingTimeInterval(60), appleUserID: "apple-test"))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionProtocol.self]
    var time = Date()
    let api = APIClient(baseURL: base, configuration: configuration, now: { time })
    var providerCalls = 0
    let state = AppState(
      api: api,
      appleCredentialState: { _ in
        providerCalls += 1
        throw URLError(.notConnectedToInternet)
      })
    SessionProtocol.handler = { request in
      if request.url?.path == "/api/blocked-members" {
        return (200, Data("{\"members\":[],\"hiddenMemberIDs\":[]}".utf8))
      }
      return (
        200,
        Data(
          "{\"user\":{\"id\":\"one\",\"name\":\"Synthetic\",\"email\":\"one@example.test\",\"role\":\"member\",\"identity\":\"pending\"},\"demo\":false}"
            .utf8)
      )
    }
    defer {
      try? api.clearSession()
      SessionProtocol.handler = nil
    }
    await state.refreshSession()
    XCTAssertEqual(state.user?.id, "one")
    XCTAssertEqual(providerCalls, 1)
    time = time.addingTimeInterval(120)
    await state.refreshSession(reportErrors: false)
    XCTAssertNil(state.user)
    XCTAssertEqual(providerCalls, 1)
    XCTAssertFalse(api.hasStoredSession)
  }
  @MainActor func testOfflineLogoutStillClearsLocalIdentity() async throws {
    let base = URL(string: "https://logout-\(UUID().uuidString).example.test")!
    let vault = KeychainSession(account: base.absoluteString)
    try vault.save(
      SessionCredential(
        cookie: "cuse_password_session=synthetic", expires: Date().addingTimeInterval(60)))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionProtocol.self]
    let api = APIClient(baseURL: base, configuration: configuration)
    let state = AppState(api: api)
    state.user = Member(
      id: "one", name: "Synthetic", email: "person@example.test", role: "member",
      identity: "pending")
    SessionProtocol.handler = { _ in (503, Data("{\"error\":\"Unavailable\"}".utf8)) }
    defer {
      try? api.clearSession()
      SessionProtocol.handler = nil
    }
    await state.logout()
    XCTAssertNil(state.user)
    XCTAssertNil(vault.read())
    XCTAssertNotNil(state.error)
  }
}
