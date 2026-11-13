import XCTest

#if PERSONAL_DEVICE
  final class PersonalDeviceTests: XCTestCase {
    @MainActor func testStandaloneCaptureCheckWithoutMarketplace() throws {
      continueAfterFailure = false
      let app = XCUIApplication()
      app.launch()
      // The scanning app opens on its property list, with no marketplace around it.
      XCTAssertTrue(app.navigationBars["Properties"].waitForExistence(timeout: 20))
      XCTAssertTrue(app.buttons["Add a property"].firstMatch.exists)
      XCTAssertFalse(app.tabBars.firstMatch.exists)
      // Adding a property leads to the pre-scan guide.
      app.buttons["Add a property"].firstMatch.tap()
      let field = app.textFields["Name or address"]
      XCTAssertTrue(field.waitForExistence(timeout: 5))
      field.typeText("12 Elm St")
      app.buttons["Add"].tap()
      XCTAssertTrue(app.navigationBars["12 Elm St"].waitForExistence(timeout: 5))
      XCTAssertTrue(app.buttons["Start scan"].waitForExistence(timeout: 5))
      app.navigationBars.buttons["Properties"].tap()
      XCTAssertTrue(app.staticTexts["Not scanned yet"].waitForExistence(timeout: 5))
      // The hardware check moved under Settings.
      app.buttons["Settings"].tap()
      app.buttons["Device capture check"].tap()
      XCTAssertTrue(app.navigationBars["Device capture check"].waitForExistence(timeout: 20))
      XCTAssertFalse(app.tabBars.firstMatch.exists)
      XCTAssertFalse(app.buttons["Log in or create an account"].exists)
      let start = app.buttons["Start camera test"]
      for _ in 0..<4 {
        if start.exists && start.isHittable { break }
        app.swipeUp()
      }
      XCTAssertTrue(start.exists)
      XCTAssertFalse(start.isEnabled, "Simulator cannot perform camera capture")
      let unavailable = app.descendants(matching: .any).matching(
        NSPredicate(format: "label CONTAINS[c] 'Unavailable' OR value CONTAINS[c] 'Unavailable'"))
      XCTAssertTrue(unavailable.firstMatch.exists, "Photographic capture reads Unavailable")
      let spots = app.buttons["Start spot capture"]
      for _ in 0..<4 {
        if spots.exists && spots.isHittable { break }
        app.swipeUp()
      }
      XCTAssertTrue(spots.exists)
      XCTAssertFalse(spots.isEnabled, "Simulator cannot perform spot capture")
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.name = "Personal Team capture test"
      screenshot.lifetime = .keepAlways
      add(screenshot)
    }
  }
#endif
