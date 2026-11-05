import XCTest

final class MarketplaceTests: XCTestCase {
  /// The complete guest → signup → draft → publish → comment → capture → logout journey.
  /// It is too long for hosted CI simulators, so it runs on the Mac mini via
  /// `npm run ios:journey`; the focused tests below cover the same features on every PR.
  @MainActor func testFullMarketplaceJourney() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["CUSE_FULL_JOURNEY"] == "1",
      "Full journey runs on the Mac mini: npm run ios:journey")
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["CUSE_API_URL"] = "http://127.0.0.1:8936"
    app.launchEnvironment["CUSE_UI_MANUAL_PASSWORD"] = "1"
    app.launch()
    XCTAssertTrue(app.navigationBars["CuseSublets"].waitForExistence(timeout: 20))
    signOutIfNeeded(app)
    app.tabBars.buttons["Browse"].tap()
    XCTAssertTrue(app.staticTexts["Find a sublet.\nList your place."].exists)
    attach(app, "Browse")
    app.buttons["Filters"].tap()
    XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Reset filters"].exists)
    XCTAssertTrue(app.switches["Furnished"].exists)
    app.buttons["Done"].tap()
    app.tabBars.buttons["Matches"].tap()
    XCTAssertTrue(app.staticTexts["Find your fit"].waitForExistence(timeout: 5))
    app.tabBars.buttons["Inbox"].tap()
    XCTAssertTrue(app.staticTexts["Your conversations"].waitForExistence(timeout: 5))
    app.tabBars.buttons["You"].tap()
    app.buttons["Log in or create an account"].tap()
    let create = app.buttons["Create an account"]
    XCTAssertTrue(create.waitForExistence(timeout: 15))
    create.tap()
    XCTAssertTrue(app.textFields["Your name"].waitForExistence(timeout: 15))
    enter("iPhone UI Test", into: app.textFields["Your name"], in: app)
    enter("iphone-\(UUID().uuidString)@example.test", into: app.textFields["Email"], in: app)
    reveal(app.secureTextFields["Password"], in: app)
    enter(
      "isolated-test-password-2026", into: app.secureTextFields["Password"], in: app, secure: true)
    reveal(app.buttons["Create account"], in: app)
    app.buttons["Create account"].tap()
    XCTAssertTrue(app.staticTexts["iPhone UI Test"].waitForExistence(timeout: 20))
    attach(app, "Account")
    app.buttons["List your place"].tap()
    XCTAssertTrue(app.textFields["Listing title"].waitForExistence(timeout: 10))
    enter("Private iPhone draft", into: app.textFields["Listing title"], in: app)
    let save = app.buttons["Save private draft & finish later"]
    reveal(save, in: app)
    save.tap()
    XCTAssertTrue(app.navigationBars["You"].waitForExistence(timeout: 10))
    app.swipeUp()
    let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume place"))
      .firstMatch
    XCTAssertTrue(resume.waitForExistence(timeout: 10))
    resume.tap()
    let neighborhood = app.textFields["Neighborhood"]
    XCTAssertTrue(neighborhood.waitForExistence(timeout: 10))
    enter("Westcott", into: neighborhood, in: app)
    reveal(app.textFields["Approximate public address"], in: app)
    enter(
      "Near Westcott — synthetic UI test", into: app.textFields["Approximate public address"],
      in: app)
    app.swipeUp()
    let description = app.descendants(matching: .any).matching(identifier: "listing-description")
      .firstMatch
    reveal(description, in: app)
    enter(
      "Synthetic simulator listing only. This is not an available property.", into: description,
      in: app)
    reveal(app.buttons["Publish listing"], in: app)
    app.buttons["Publish listing"].tap()
    XCTAssertTrue(
      app.staticTexts["Your place is published. Checks are still independent."].waitForExistence(
        timeout: 15))
    attach(app, "Published sample listing")
    app.buttons["Add photos, room scans & documents"].tap()
    app.buttons["View listing"].tap()
    let comment = app.descendants(matching: .any).matching(identifier: "comment-draft").firstMatch
    reveal(comment, in: app)
    let initialComment = "Synthetic public comment"
    enter(initialComment, into: comment, in: app)
    reveal(app.buttons["Post"], in: app)
    app.buttons["Post"].tap()
    XCTAssertTrue(app.staticTexts[initialComment].waitForExistence(timeout: 10))
    app.buttons["Edit"].tap()
    reveal(comment, in: app)
    comment.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 60), "Keyboard never appeared")
    // Focusing this multiline field places the caret at the start. Test an explicit insertion.
    comment.typeText("Edited ")
    XCTAssertEqual(comment.value as? String, "Edited " + initialComment)
    reveal(app.buttons["Save comment"], in: app)
    app.buttons["Save comment"].tap()
    XCTAssertTrue(app.staticTexts["Edited " + initialComment].waitForExistence(timeout: 10))
    attach(app, "Edited listing comment")
    app.navigationBars.buttons.firstMatch.tap()
    app.buttons["Capture or manage room layouts"].tap()
    XCTAssertTrue(
      app.staticTexts["Room scanning needs a LiDAR-equipped iPhone."].waitForExistence(timeout: 10))
    attach(app, "Room capture capability")
    // Return through the two pushed screens and close the editor explicitly.
    app.navigationBars.buttons.firstMatch.tap()
    app.navigationBars.buttons.firstMatch.tap()
    app.buttons["Done"].tap()
    app.tabBars.buttons["You"].tap()
    reveal(app.buttons["Log out"], in: app)
    app.buttons["Log out"].tap()
    app.tabBars.buttons["You"].tap()
    XCTAssertTrue(app.buttons["Log in or create an account"].waitForExistence(timeout: 10))
  }
  @MainActor func testSignedOutBrowseFiltersAndTabs() throws {
    continueAfterFailure = false
    let app = launchApp()
    signOutIfNeeded(app)
    app.tabBars.buttons["Browse"].tap()
    XCTAssertTrue(
      app.staticTexts["Find a sublet.\nList your place."].waitForExistence(timeout: 10))
    attach(app, "Browse")
    app.buttons["Filters"].tap()
    XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Reset filters"].exists)
    XCTAssertTrue(app.switches["Furnished"].exists)
    app.buttons["Done"].tap()
    app.tabBars.buttons["Matches"].tap()
    XCTAssertTrue(app.staticTexts["Find your fit"].waitForExistence(timeout: 10))
    app.tabBars.buttons["Inbox"].tap()
    XCTAssertTrue(app.staticTexts["Your conversations"].waitForExistence(timeout: 10))
  }
  @MainActor func testSignupClosesSheetAndLogoutReturnsToGuest() throws {
    continueAfterFailure = false
    let app = launchApp()
    signOutIfNeeded(app)
    app.buttons["Log in or create an account"].tap()
    let create = app.buttons["Create an account"]
    XCTAssertTrue(create.waitForExistence(timeout: 15))
    create.tap()
    enter("iPhone UI Test", into: app.textFields["Your name"], in: app)
    enter("iphone-\(UUID().uuidString)@example.test", into: app.textFields["Email"], in: app)
    reveal(app.secureTextFields["Password"], in: app)
    enter(
      "isolated-test-password-2026", into: app.secureTextFields["Password"], in: app, secure: true)
    reveal(app.buttons["Create account"], in: app)
    app.buttons["Create account"].tap()
    XCTAssertTrue(
      app.navigationBars["Welcome"].waitForNonExistence(timeout: 20),
      "Login sheet stayed open after signup")
    XCTAssertTrue(app.staticTexts["iPhone UI Test"].waitForExistence(timeout: 20))
    attach(app, "Account")
    reveal(app.buttons["Log out"], in: app)
    app.buttons["Log out"].tap()
    app.tabBars.buttons["You"].tap()
    XCTAssertTrue(app.buttons["Log in or create an account"].waitForExistence(timeout: 10))
  }
  @MainActor func testPrivateDraftResumesAndPublishes() async throws {
    continueAfterFailure = false
    let member = try await seedMember()
    let app = launchApp(session: member.cookie)
    app.tabBars.buttons["You"].tap()
    XCTAssertTrue(app.staticTexts[member.name].waitForExistence(timeout: 20))
    reveal(app.buttons["List your place"], in: app)
    app.buttons["List your place"].tap()
    enter("Private iPhone draft", into: app.textFields["Listing title"], in: app)
    let save = app.buttons["Save private draft & finish later"]
    reveal(save, in: app)
    save.tap()
    XCTAssertTrue(app.navigationBars["You"].waitForExistence(timeout: 10))
    let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume place"))
      .firstMatch
    XCTAssertTrue(resume.waitForExistence(timeout: 10))
    reveal(resume, in: app)
    resume.tap()
    let neighborhood = app.textFields["Neighborhood"]
    XCTAssertTrue(neighborhood.waitForExistence(timeout: 10))
    XCTAssertEqual(app.textFields["Listing title"].value as? String, "Private iPhone draft")
    enter("Westcott", into: neighborhood, in: app)
    reveal(app.textFields["Approximate public address"], in: app)
    enter(
      "Near Westcott — synthetic UI test", into: app.textFields["Approximate public address"],
      in: app)
    let description = app.descendants(matching: .any).matching(identifier: "listing-description")
      .firstMatch
    reveal(description, in: app)
    enter(
      "Synthetic simulator listing only. This is not an available property.", into: description,
      in: app)
    reveal(app.buttons["Publish listing"], in: app)
    app.buttons["Publish listing"].tap()
    XCTAssertTrue(
      app.staticTexts["Your place is published. Checks are still independent."].waitForExistence(
        timeout: 15))
    attach(app, "Published sample listing")
  }
  @MainActor func testListingCommentPostsAndEdits() async throws {
    continueAfterFailure = false
    let member = try await seedMember()
    let title = try await seedListing(for: member)
    let app = launchApp(session: member.cookie)
    openOwnListing(title, in: app)
    app.buttons["View listing"].tap()
    let comment = app.descendants(matching: .any).matching(identifier: "comment-draft").firstMatch
    reveal(comment, in: app)
    let initialComment = "Synthetic public comment"
    enter(initialComment, into: comment, in: app)
    reveal(app.buttons["Post"], in: app)
    app.buttons["Post"].tap()
    XCTAssertTrue(app.staticTexts[initialComment].waitForExistence(timeout: 10))
    app.buttons["Edit"].tap()
    reveal(comment, in: app)
    comment.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 60), "Keyboard never appeared")
    // Focusing this multiline field places the caret at the start. Test an explicit insertion.
    comment.typeText("Edited ")
    XCTAssertEqual(comment.value as? String, "Edited " + initialComment)
    reveal(app.buttons["Save comment"], in: app)
    app.buttons["Save comment"].tap()
    XCTAssertTrue(app.staticTexts["Edited " + initialComment].waitForExistence(timeout: 10))
    attach(app, "Edited listing comment")
  }
  @MainActor func testRoomLayoutCaptureExplainsLiDARRequirement() async throws {
    continueAfterFailure = false
    let member = try await seedMember()
    let title = try await seedListing(for: member)
    let app = launchApp(session: member.cookie)
    openOwnListing(title, in: app)
    let layouts = app.buttons["Capture or manage room layouts"]
    reveal(layouts, in: app)
    layouts.tap()
    XCTAssertTrue(
      app.staticTexts["Room scanning needs a LiDAR-equipped iPhone."].waitForExistence(timeout: 10))
    attach(app, "Room capture capability")
  }
  @MainActor func testLocalDeviceCheckDoesNotRequireAccountOrSupportedCamera() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["CUSE_API_URL"] = "http://127.0.0.1:8936"
    app.launch()
    XCTAssertTrue(app.navigationBars["CuseSublets"].waitForExistence(timeout: 20))
    signOutIfNeeded(app)
    reveal(app.buttons["Device capture check"], in: app)
    app.buttons["Device capture check"].tap()
    XCTAssertTrue(app.navigationBars["Device capture check"].waitForExistence(timeout: 10))
    let start = app.buttons["Start camera test"]
    reveal(start, in: app)
    XCTAssertFalse(start.isEnabled, "Simulator must not pretend camera capture works")
    attach(app, "Local device capture check")
  }
  @MainActor func testPrivacyNoticeAtLargestDynamicType() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["CUSE_API_URL"] = "http://127.0.0.1:8936"
    app.launchArguments += [
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    XCTAssertTrue(app.navigationBars["CuseSublets"].waitForExistence(timeout: 20))
    signOutIfNeeded(app)
    reveal(app.buttons["Data & privacy"], in: app)
    app.buttons["Data & privacy"].tap()
    XCTAssertTrue(app.navigationBars["Data & privacy"].waitForExistence(timeout: 10))
    XCTAssertTrue(
      app.staticTexts["Development preview. Public release and real transactions are not enabled."]
        .exists)
    attach(app, "Privacy notice at largest Dynamic Type")
  }
  @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    if app.keyboards.firstMatch.exists {
      let done = app.buttons["dismiss-keyboard"]
      XCTAssertTrue(done.waitForExistence(timeout: 10))
      done.tap()
      XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
    }
    // Floating tab bars can cover controls that XCTest still reports as hittable.
    // Bring the whole control clear of the actual bars before asking XCTest to tap it.
    func safeTop() -> CGFloat {
      let bar = app.navigationBars.firstMatch
      return bar.exists ? bar.frame.maxY + 4 : app.frame.minY
    }
    func safeBottom() -> CGFloat {
      let bar = app.tabBars.firstMatch
      return bar.exists ? bar.frame.minY - 4 : app.frame.maxY
    }
    func safelyVisible() -> Bool {
      guard element.exists && element.isHittable else { return false }
      let frame = element.frame
      return frame.minY >= safeTop() && frame.maxY <= safeBottom()
    }
    for _ in 0..<8 {
      if safelyVisible() { return }
      // Scroll along the form margin so embedded maps do not consume the gesture.
      let above = element.exists && element.frame.minY < safeTop()
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: above ? 0.3 : 0.75))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: above ? 0.75 : 0.3))
      start.press(forDuration: 0.05, thenDragTo: end)
    }
    XCTAssertTrue(safelyVisible(), "Expected a form control clear of navigation and tab bars")
  }
  /// Hosted simulators can show the software keyboard many seconds after a field gains focus,
  /// and keystrokes sent before it appears are silently dropped. Wait for the keyboard, then
  /// confirm the field holds exactly the text instead of trusting typeText.
  @MainActor private func enter(
    _ text: String, into field: XCUIElement, in app: XCUIApplication, secure: Bool = false
  ) {
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    func current() -> String {
      let value = field.value as? String ?? ""
      return value == field.placeholderValue ? "" : value
    }
    func holdsText() -> Bool { secure ? current().count == text.count : current() == text }
    for _ in 0..<3 {
      // Tap near the trailing edge so the caret lands after any partial text.
      field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
      guard app.keyboards.firstMatch.waitForExistence(timeout: 60) else { continue }
      let partial = current().count
      if partial > 0 {
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: partial))
      }
      field.typeText(text)
      if holdsText() { return }
    }
    XCTFail(
      "\(field.identifier.isEmpty ? field.label : field.identifier) did not accept the typed text")
  }
  private static let apiBase = "http://127.0.0.1:8936"
  private struct SeededMember {
    let name: String
    let cookie: String
  }
  @MainActor private func launchApp(session cookie: String? = nil) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["CUSE_API_URL"] = Self.apiBase
    app.launchEnvironment["CUSE_UI_MANUAL_PASSWORD"] = "1"
    if let cookie { app.launchEnvironment["CUSE_UI_SESSION_COOKIE"] = cookie }
    app.launch()
    XCTAssertTrue(app.navigationBars["CuseSublets"].waitForExistence(timeout: 20))
    return app
  }
  /// Creates state directly on the isolated local API so each test drives only its own feature.
  private func post(_ path: String, _ body: [String: Any], cookie: String? = nil) async throws
    -> HTTPURLResponse
  {
    var request = URLRequest(url: try XCTUnwrap(URL(string: Self.apiBase + path)))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(Self.apiBase, forHTTPHeaderField: "Origin")
    if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    XCTAssertTrue(
      (200..<300).contains(http.statusCode),
      "\(path) returned \(http.statusCode): \(String(decoding: data, as: UTF8.self))")
    return http
  }
  private func seedMember() async throws -> SeededMember {
    let name = "Seeded UI Test"
    let response = try await post(
      "/api/auth/signup",
      [
        "email": "seeded-\(UUID().uuidString)@example.test",
        "password": "isolated-test-password-2026", "name": name,
      ])
    let header = try XCTUnwrap(response.value(forHTTPHeaderField: "Set-Cookie"))
    let cookie = try XCTUnwrap(header.split(separator: ";").first.map(String.init))
    XCTAssertTrue(cookie.hasPrefix("cuse_password_session="), "Unexpected session cookie")
    return SeededMember(name: name, cookie: cookie)
  }
  private func seedListing(for member: SeededMember) async throws -> String {
    let title = "Seeded listing \(UUID().uuidString.prefix(6))"
    let day: TimeInterval = 86_400
    let format = DateFormatter()
    format.calendar = Calendar(identifier: .gregorian)
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(identifier: "America/New_York")
    format.dateFormat = "yyyy-MM-dd"
    let body: [String: Any] = [
      "title": title, "neighborhood": "Westcott", "address": "Approximate synthetic test area",
      "price": 800, "beds": 1, "baths": 1, "roomType": "Private room",
      "startDate": format.string(from: Date().addingTimeInterval(30 * day)),
      "endDate": format.string(from: Date().addingTimeInterval(180 * day)),
      "description": "Synthetic simulator listing only. This is not an available property.",
      "amenities": [String](), "images": [String](), "lat": 43.04, "lng": -76.13,
    ]
    _ = try await post("/api/listings", body, cookie: member.cookie)
    return title
  }
  @MainActor private func openOwnListing(_ title: String, in app: XCUIApplication) {
    app.tabBars.buttons["You"].tap()
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 20), "Seeded listing missing from Your places")
    reveal(row, in: app)
    row.tap()
    XCTAssertTrue(app.buttons["View listing"].waitForExistence(timeout: 10))
  }
  @MainActor private func signOutIfNeeded(_ app: XCUIApplication) {
    app.tabBars.buttons["You"].tap()
    let login = app.buttons["Log in or create an account"]
    if login.waitForExistence(timeout: 3) { return }
    let logout = app.buttons["Log out"]
    reveal(logout, in: app)
    logout.tap()
    XCTAssertTrue(app.navigationBars["CuseSublets"].waitForExistence(timeout: 15))
    app.tabBars.buttons["You"].tap()
    XCTAssertTrue(login.waitForExistence(timeout: 10))
  }
  @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
    let a = XCTAttachment(screenshot: app.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
  }
}
