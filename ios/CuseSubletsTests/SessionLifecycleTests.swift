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
  @MainActor func testTourCookieKeepsSessionProtectionsAndExpires() throws {
    let base = URL(string: "https://cookie-\(UUID().uuidString).example.test")!
    let vault = KeychainSession(account: base.absoluteString)
    let expires = Date().addingTimeInterval(60)
    try vault.save(.init(cookie: "cuse_password_session=synthetic", expires: expires))
    var time = Date()
    let api = APIClient(baseURL: base, now: { time })
    defer { try? api.clearSession() }
    let cookie = try XCTUnwrap(api.webSessionCookie())
    XCTAssertTrue(cookie.isHTTPOnly)
    XCTAssertTrue(cookie.isSecure)
    XCTAssertEqual(cookie.sameSitePolicy, .sameSiteLax)
    XCTAssertEqual(cookie.domain, base.host?.lowercased())
    XCTAssertEqual(cookie.value, "synthetic")
    time = expires.addingTimeInterval(1)
    XCTAssertNil(api.webSessionCookie())
  }
  @MainActor func testSearchPublicationSurvivesDraftCleanupFailure() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionProtocol.self]
    let api = APIClient(
      baseURL: URL(string: "https://search.example.test"), configuration: configuration)
    var paths: [String] = []
    SessionProtocol.handler = { request in
      paths.append(request.url!.path)
      return request.url!.path == "/api/my-search"
        ? (200, Data("{}".utf8))
        : (503, Data("{\"error\":\"Unavailable\"}".utf8))
    }
    defer { SessionProtocol.handler = nil }
    let cleaned = try await api.publishHousingSearch(["status": "active"], draftRevision: 3)
    XCTAssertFalse(cleaned)
    XCTAssertEqual(paths, ["/api/my-search", "/api/drafts/search/delete"])
    paths = []
    SessionProtocol.handler = { request in
      paths.append(request.url!.path)
      return (400, Data("{\"error\":\"Invalid search\"}".utf8))
    }
    do {
      _ = try await api.publishHousingSearch([:], draftRevision: 3)
      XCTFail("Failed publication must remain a failure")
    } catch {}
    XCTAssertEqual(paths, ["/api/my-search"])
  }
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
  /// Signup's own refresh can be superseded by the periodic or foreground refresh. Whichever
  /// refresh observes the signed-in member must close the login sheet.
  @MainActor func testSupersededSignInRefreshStillClosesLoginSheet() async throws {
    let base = URL(string: "https://login-race-\(UUID().uuidString).example.test")!
    let vault = KeychainSession(account: base.absoluteString)
    try vault.save(
      SessionCredential(
        cookie: "cuse_password_session=synthetic", expires: Date().addingTimeInterval(60)))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionProtocol.self]
    let api = APIClient(baseURL: base, configuration: configuration)
    let state = AppState(api: api)
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
    state.showLogin = true
    // Only the periodic refresh completes here, as when it supersedes signup's own refresh.
    await state.refreshSession(reportErrors: false)
    XCTAssertEqual(state.user?.id, "one")
    XCTAssertFalse(state.showLogin, "Signed-in member left behind an open login sheet")
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
  private static let signedInSession =
    "{\"user\":{\"id\":\"one\",\"name\":\"Synthetic\",\"email\":\"one@example.test\",\"role\":\"member\",\"identity\":\"pending\"},\"demo\":false}"
  /// An app state whose saved session the server has not yet been asked about.
  @MainActor private func stateWithSavedSession(_ name: String) throws -> AppState {
    let base = URL(string: "https://\(name)-\(UUID().uuidString).example.test")!
    try KeychainSession(account: base.absoluteString).save(
      SessionCredential(
        cookie: "cuse_password_session=synthetic", expires: Date().addingTimeInterval(60)))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionProtocol.self]
    return AppState(api: APIClient(baseURL: base, configuration: configuration))
  }
  /// Just after the app opens, a signed-in person's session is still being checked. A tap that
  /// needs an account must wait for that answer, not show them the login sheet.
  @MainActor func testATapThatNeedsAnAccountWaitsForTheSavedSessionCheck() async throws {
    let state = try stateWithSavedSession("early-tap")
    SessionProtocol.handler = { request in
      request.url?.path == "/api/blocked-members"
        ? (200, Data("{\"members\":[],\"hiddenMemberIDs\":[]}".utf8))
        : (200, Data(Self.signedInSession.utf8))
    }
    defer {
      try? state.api.clearSession()
      SessionProtocol.handler = nil
    }
    XCTAssertTrue(state.checkingSavedSession)
    let tapped = Task { await state.signedInOrAsk() }
    for _ in 0..<5 { await Task.yield() }
    XCTAssertFalse(state.showLogin, "The saved session has not been checked yet")
    await state.refreshSession()
    let signedIn = await tapped.value
    XCTAssertTrue(signedIn)
    XCTAssertFalse(state.showLogin)
    XCTAssertFalse(state.checkingSavedSession)
  }
  @MainActor func testATapThatNeedsAnAccountAsksAGuestToLogInAtOnce() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionProtocol.self]
    let api = APIClient(
      baseURL: URL(string: "https://guest-\(UUID().uuidString).example.test"),
      configuration: configuration)
    let state = AppState(api: api)
    XCTAssertFalse(state.checkingSavedSession, "A guest has no saved session to check")
    let signedIn = await state.signedInOrAsk()
    XCTAssertFalse(signedIn)
    XCTAssertTrue(state.showLogin)
  }
  @MainActor func testATapThatNeedsAnAccountAsksForLoginWhenTheSavedSessionHasEnded() async throws {
    let state = try stateWithSavedSession("ended")
    SessionProtocol.handler = { _ in (200, Data("{\"user\":null,\"demo\":false}".utf8)) }
    defer {
      try? state.api.clearSession()
      SessionProtocol.handler = nil
    }
    let tapped = Task { await state.signedInOrAsk() }
    for _ in 0..<5 { await Task.yield() }
    await state.refreshSession(reportErrors: false)
    let signedIn = await tapped.value
    XCTAssertFalse(signedIn)
    XCTAssertTrue(state.showLogin)
    XCTAssertFalse(state.checkingSavedSession)
  }
}
