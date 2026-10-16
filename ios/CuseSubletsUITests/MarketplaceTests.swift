import XCTest

final class MarketplaceTests: XCTestCase {
  @MainActor func testPublicBrowseAndSignedInNavigation() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["CUSE_API_URL"] = "http://127.0.0.1:8936"
    app.launchEnvironment["CUSE_UI_MANUAL_PASSWORD"] = "1"
    app.launch()
    XCTAssertTrue(app.navigationBars["CuseSublets"].waitForExistence(timeout: 20))
    XCTAssertTrue(app.staticTexts["Find a sublet.\nList your place."].exists)
    attach(app, "Browse")
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
    app.textFields["Your name"].tap()
    app.textFields["Your name"].typeText("iPhone UI Test")
    app.textFields["Email"].tap()
    app.textFields["Email"].typeText("iphone-\(UUID().uuidString)@example.test")
    reveal(app.secureTextFields["Password"], in: app)
    app.secureTextFields["Password"].tap()
    app.secureTextFields["Password"].typeText("isolated-test-password-2026")
    reveal(app.buttons["Create account"], in: app)
    app.buttons["Create account"].tap()
    XCTAssertTrue(app.staticTexts["iPhone UI Test"].waitForExistence(timeout: 20))
    attach(app, "Account")
    app.buttons["List your place"].tap()
    XCTAssertTrue(app.textFields["Listing title"].waitForExistence(timeout: 10))
    app.textFields["Listing title"].tap()
    app.textFields["Listing title"].typeText("Private iPhone draft")
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
    neighborhood.tap()
    neighborhood.typeText("Westcott")
    reveal(app.textFields["Approximate public address"], in: app)
    app.textFields["Approximate public address"].tap()
    app.textFields["Approximate public address"].typeText("Near Westcott — synthetic UI test")
    app.swipeUp()
    let description = app.descendants(matching: .any).matching(identifier: "listing-description")
      .firstMatch
    reveal(description, in: app)
    description.tap()
    description.typeText("Synthetic simulator listing only. This is not an available property.")
    reveal(app.buttons["Publish listing"], in: app)
    app.buttons["Publish listing"].tap()
    XCTAssertTrue(
      app.staticTexts["Your place is published. Checks are still independent."].waitForExistence(
        timeout: 15))
    attach(app, "Published sample listing")
    app.buttons["Add photos, room scans & documents"].tap()
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
  @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    if app.keyboards.firstMatch.exists {
      let done = app.buttons["dismiss-keyboard"]
      XCTAssertTrue(done.waitForExistence(timeout: 10))
      done.tap()
      XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
    }
    for _ in 0..<8 {
      if element.exists && element.isHittable { return }
      // Scroll along the form margin so embedded maps do not consume the gesture.
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.75))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.3))
      start.press(forDuration: 0.05, thenDragTo: end)
    }
    XCTAssertTrue(element.exists && element.isHittable, "Expected a visible form control")
  }
  @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
    let a = XCTAttachment(screenshot: app.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
  }
}
