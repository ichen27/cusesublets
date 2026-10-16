import XCTest

final class MarketplaceTests: XCTestCase {
  @MainActor func testPublicBrowseAndSignedInNavigation() throws {
    let app = XCUIApplication()
    app.launchEnvironment["CUSE_API_URL"] = "http://127.0.0.1:8936"
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
    let create = app.switches["Create an account"]
    XCTAssertTrue(create.waitForExistence(timeout: 5))
    create.tap()
    app.textFields["Your name"].tap()
    app.textFields["Your name"].typeText("iPhone UI Test")
    app.textFields["Email"].tap()
    app.textFields["Email"].typeText("iphone-\(UUID().uuidString)@example.test")
    app.secureTextFields["Password"].tap()
    app.secureTextFields["Password"].typeText("isolated-test-password-2026")
    app.buttons["Create account"].tap()
    XCTAssertTrue(app.staticTexts["iPhone UI Test"].waitForExistence(timeout: 20))
    attach(app, "Account")
    app.buttons["List your place"].tap()
    XCTAssertTrue(app.textFields["Listing title"].waitForExistence(timeout: 10))
    app.textFields["Listing title"].tap()
    app.textFields["Listing title"].typeText("Private iPhone draft")
    app.swipeUp()
    app.swipeUp()
    app.swipeUp()
    let save = app.buttons["Save private draft & finish later"]
    XCTAssertTrue(save.waitForExistence(timeout: 5))
    save.tap()
    XCTAssertTrue(app.navigationBars["You"].waitForExistence(timeout: 10))
    app.swipeUp()
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume place")).firstMatch
        .waitForExistence(timeout: 10))
    app.swipeUp()
    app.buttons["Log out"].tap()
    app.tabBars.buttons["You"].tap()
    XCTAssertTrue(app.buttons["Log in or create an account"].waitForExistence(timeout: 10))
  }
  @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
    let a = XCTAttachment(screenshot: app.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
  }
}
