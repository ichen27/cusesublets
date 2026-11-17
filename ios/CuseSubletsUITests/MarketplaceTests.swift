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
    XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 30))
    signOutIfNeeded(app)
    app.buttons["tab-home"].tap()
    XCTAssertTrue(app.staticTexts["Quad"].exists)
    attach(app, "Browse")
    app.buttons["Filters"].tap()
    XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.buttons["Reset filters"].exists)
    XCTAssertTrue(app.switches["Furnished"].exists)
    app.buttons["Done"].tap()
    app.buttons["tab-matches"].tap()
    XCTAssertTrue(app.staticTexts["Find your fit"].waitForExistence(timeout: 5))
    app.buttons["tab-inbox"].tap()
    XCTAssertTrue(app.staticTexts["Your conversations"].waitForExistence(timeout: 5))
    app.buttons["tab-you"].tap()
    app.buttons["Log in or create an account"].tap()
    let create = app.buttons["Create an account"]
    XCTAssertTrue(create.waitForExistence(timeout: 30))
    create.tap()
    XCTAssertTrue(app.textFields["Your name"].waitForExistence(timeout: 30))
    enter("iPhone UI Test", into: app.textFields["Your name"], in: app)
    enter("iphone-\(UUID().uuidString)@example.test", into: app.textFields["Email"], in: app)
    reveal(app.secureTextFields["Password"], in: app)
    enter(
      "isolated-test-password-2026", into: app.secureTextFields["Password"], in: app, secure: true)
    reveal(app.buttons["Create account"], in: app)
    app.buttons["Create account"].tap()
    XCTAssertTrue(app.staticTexts["iPhone UI Test"].waitForExistence(timeout: 30))
    attach(app, "Account")
    app.buttons["List your place"].tap()
    XCTAssertTrue(app.textFields["Neighborhood"].waitForExistence(timeout: 30))
    enter("Westcott", into: app.textFields["Neighborhood"], in: app)
    tapOutsideTheForm("Save and finish later", in: app)
    XCTAssertTrue(app.navigationBars["You"].waitForExistence(timeout: 30))
    app.swipeUp()
    let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume place"))
      .firstMatch
    XCTAssertTrue(resume.waitForExistence(timeout: 30))
    resume.tap()
    fillPlaceAndDetails(title: "Private iPhone draft", in: app)
    skipToChecksAndPublish(in: app)
    attach(app, "Published sample listing")
    app.buttons["Manage my place"].tap()
    app.buttons["View listing"].tap()
    let comment = app.descendants(matching: .any).matching(identifier: "comment-draft").firstMatch
    reveal(comment, in: app)
    let initialComment = "Synthetic public comment"
    enter(initialComment, into: comment, in: app)
    reveal(app.buttons["Post"], in: app)
    app.buttons["Post"].tap()
    XCTAssertTrue(app.staticTexts[initialComment].waitForExistence(timeout: 30))
    app.buttons["Edit"].tap()
    reveal(comment, in: app)
    comment.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 60), "Keyboard never appeared")
    // Focusing this multiline field places the caret at the start. Test an explicit insertion.
    comment.typeText("Edited ")
    XCTAssertEqual(comment.value as? String, "Edited " + initialComment)
    reveal(app.buttons["Save comment"], in: app)
    app.buttons["Save comment"].tap()
    XCTAssertTrue(app.staticTexts["Edited " + initialComment].waitForExistence(timeout: 30))
    attach(app, "Edited listing comment")
    // A sublease's page draws its own Back button over the photo.
    reveal(app.buttons["Back"], in: app)
    app.buttons["Back"].tap()
    app.buttons["Capture or manage room layouts"].tap()
    XCTAssertTrue(
      app.staticTexts["Room scanning needs a LiDAR-equipped iPhone."].waitForExistence(timeout: 30))
    attach(app, "Room capture capability")
    // Return through the two pushed screens and close the listing steps explicitly.
    app.navigationBars.buttons.firstMatch.tap()
    app.navigationBars.buttons.firstMatch.tap()
    app.buttons["Done"].tap()
    app.buttons["tab-you"].tap()
    logOut(in: app)
  }
  @MainActor func testSignedOutBrowseFiltersAndTabs() throws {
    continueAfterFailure = false
    let app = launchApp()
    signOutIfNeeded(app)
    app.buttons["tab-home"].tap()
    XCTAssertTrue(
      app.staticTexts["Quad"].waitForExistence(timeout: 30))
    attach(app, "Browse")
    app.buttons["Filters"].tap()
    XCTAssertTrue(app.navigationBars["Filters"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.buttons["Reset filters"].exists)
    XCTAssertTrue(app.switches["Furnished"].exists)
    app.buttons["Done"].tap()
    app.buttons["tab-matches"].tap()
    XCTAssertTrue(app.staticTexts["Find your fit"].waitForExistence(timeout: 30))
    app.buttons["tab-inbox"].tap()
    XCTAssertTrue(app.staticTexts["Your conversations"].waitForExistence(timeout: 30))
  }
  @MainActor func testSignupClosesSheetAndLogoutReturnsToGuest() throws {
    continueAfterFailure = false
    let app = launchApp()
    signOutIfNeeded(app)
    app.buttons["Log in or create an account"].tap()
    let create = app.buttons["Create an account"]
    XCTAssertTrue(create.waitForExistence(timeout: 30))
    create.tap()
    enter("iPhone UI Test", into: app.textFields["Your name"], in: app)
    enter("iphone-\(UUID().uuidString)@example.test", into: app.textFields["Email"], in: app)
    reveal(app.secureTextFields["Password"], in: app)
    enter(
      "isolated-test-password-2026", into: app.secureTextFields["Password"], in: app, secure: true)
    reveal(app.buttons["Create account"], in: app)
    app.buttons["Create account"].tap()
    XCTAssertTrue(
      app.navigationBars["Welcome"].waitForNonExistence(timeout: 30),
      "Login sheet stayed open after signup")
    XCTAssertTrue(app.staticTexts["iPhone UI Test"].waitForExistence(timeout: 30))
    attach(app, "Account")
    logOut(in: app)
  }
  @MainActor func testPostButtonOffersBothKindsAndOpensTheListingSteps() throws {
    continueAfterFailure = false
    let member = try seedMember()
    let app = launchApp(session: member.cookie)
    app.buttons["tab-post"].tap()
    XCTAssertTrue(app.buttons["Say what I'm looking for"].waitForExistence(timeout: 30))
    app.buttons["Sublease my place"].tap()
    XCTAssertTrue(app.staticTexts["Where is your place?"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["Step 1 of 5 · Where"].exists)
    attach(app, "Listing steps from the Post button")
  }
  @MainActor func testPostButtonAsksAGuestToLogIn() throws {
    let app = XCUIApplication()
    app.launchEnvironment["CUSE_API_URL"] = Self.apiBase
    app.launchEnvironment["CUSE_UI_MANUAL_PASSWORD"] = "1"
    app.launch()
    XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 30))
    signOutIfNeeded(app)
    app.buttons["tab-post"].tap()
    XCTAssertTrue(app.buttons["Create an account"].waitForExistence(timeout: 30))
    XCTAssertFalse(app.buttons["Sublease my place"].exists)
  }
  @MainActor func testPrivateDraftResumesAndPublishes() throws {
    continueAfterFailure = false
    let member = try seedMember()
    let app = launchApp(session: member.cookie)
    app.buttons["tab-you"].tap()
    XCTAssertTrue(app.staticTexts[member.name].waitForExistence(timeout: 30))
    reveal(app.buttons["List your place"], in: app)
    app.buttons["List your place"].tap()
    enter("Westcott", into: app.textFields["Neighborhood"], in: app)
    tapOutsideTheForm("Save and finish later", in: app)
    XCTAssertTrue(app.navigationBars["You"].waitForExistence(timeout: 30))
    let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume place"))
      .firstMatch
    XCTAssertTrue(resume.waitForExistence(timeout: 30))
    reveal(resume, in: app)
    resume.tap()
    let neighborhood = app.textFields["Neighborhood"]
    XCTAssertTrue(neighborhood.waitForExistence(timeout: 30))
    XCTAssertEqual(neighborhood.value as? String, "Westcott", "The draft was not restored")
    fillPlaceAndDetails(title: "Private iPhone draft", fillNeighborhood: false, in: app)
    XCTAssertTrue(
      app.staticTexts["Your place is saved and not published yet. Nobody else can see it."].exists)
    skipToChecksAndPublish(in: app)
    attach(app, "Published sample listing")
    app.buttons["Done"].tap()
    XCTAssertTrue(app.navigationBars["You"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["Published"].waitForExistence(timeout: 30))
    XCTAssertFalse(
      app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume place")).firstMatch
        .exists, "The private draft should be gone once its place exists")
  }
  /// Typing the first steps by hand is covered by `testPrivateDraftResumesAndPublishes`; this
  /// place is left unpublished through the API, so the test drives only finishing it.
  @MainActor func testAPlaceLeftUnpublishedIsFinishedFromItsPage() throws {
    continueAfterFailure = false
    let member = try seedMember()
    let title = try seedListing(for: member, publish: false)
    let app = launchApp(session: member.cookie)
    app.buttons["tab-you"].tap()
    XCTAssertTrue(app.staticTexts["Not published"].waitForExistence(timeout: 30))
    openOwnListing(title, in: app)
    let finish = app.buttons["Add photos, a scan and checks in steps"]
    finish.tap()
    let photos = app.staticTexts["Add photos"]
    XCTAssertTrue(photos.waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["Step 3 of 5 · Photos"].exists)
    // Leaving here keeps the place unpublished, and it can be picked up again.
    tapOutsideTheForm("Finish later", in: app)
    XCTAssertTrue(photos.waitForNonExistence(timeout: 30))
    finish.tap()
    XCTAssertTrue(photos.waitForExistence(timeout: 30))
    skipToChecksAndPublish(in: app)
  }
  @MainActor func testMatchesShowOneAtATimeWithPassBackAndStartAgain() throws {
    continueAfterFailure = false
    let seeker = try seedMember(name: "Sam Seeker")
    let spot = freshSpot()
    try seedSearch(for: seeker, around: spot)
    // The cheaper place ranks first, so the order of the deck is known.
    let first = try seedListing(
      for: try seedMember(name: "Jamie Host"), price: 700, at: spot)
    let second = try seedListing(
      for: try seedMember(name: "Riley Host"), price: 800, at: spot)
    let app = launchApp(session: seeker.cookie)
    app.buttons["tab-matches"].tap()
    let position = app.staticTexts["match-position"]
    XCTAssertTrue(position.waitForExistence(timeout: 30))
    wait(for: position, toBe: "label == '1 of 2 that fit'", "The matches did not load")
    XCTAssertTrue(matchCard(first, in: app).exists)
    XCTAssertFalse(matchCard(second, in: app).exists, "Only one match shows at a time")
    XCTAssertTrue(app.staticTexts["For your search"].exists)
    XCTAssertTrue(app.staticTexts["Why it fits your search"].exists)
    XCTAssertTrue(app.staticTexts["Inside your $1,000 budget"].exists)
    XCTAssertTrue(app.staticTexts["In your Westcott area"].exists)
    XCTAssertTrue(app.buttons["Message Jamie"].exists)
    attach(app, "Matches: a place that fits")

    app.buttons["Pass"].tap()
    XCTAssertTrue(matchCard(second, in: app).waitForExistence(timeout: 5))
    XCTAssertEqual(position.label, "2 of 2 that fit")
    XCTAssertTrue(app.buttons["Message Riley"].exists)

    app.buttons["Back to the last match"].tap()
    XCTAssertTrue(matchCard(first, in: app).waitForExistence(timeout: 5))
    XCTAssertEqual(position.label, "1 of 2 that fit")

    // Dragging the card off to the left passes on it too.
    // Lifting the finger after a drag must not count as a tap that opens the place.
    let card = matchCard(first, in: app)
    card.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).press(
      forDuration: 0.1,
      thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)))
    XCTAssertTrue(matchCard(second, in: app).waitForExistence(timeout: 5))
    app.buttons["Pass"].tap()
    XCTAssertTrue(app.staticTexts["You've seen all 2"].waitForExistence(timeout: 5))
    attach(app, "Matches: seen them all")
    app.buttons["Start again"].tap()
    XCTAssertTrue(matchCard(first, in: app).waitForExistence(timeout: 5))

    // A tap opens the place, and coming back leaves the deck where it was.
    matchCard(first, in: app).tap()
    XCTAssertTrue(app.otherElements["listing-price-bar"].waitForExistence(timeout: 30))
    app.buttons["Back"].tap()
    XCTAssertTrue(position.waitForExistence(timeout: 30))
    XCTAssertEqual(position.label, "1 of 2 that fit")
  }
  @MainActor func testASubleaserSeesPeopleWhoseSearchFitsTheirPlace() throws {
    continueAfterFailure = false
    let spot = freshSpot()
    let host = try seedMember(name: "Harper Host")
    let place = try seedListing(for: host, price: 800, at: spot)
    try seedSearch(for: try seedMember(name: "Sam Seeker"), around: spot)
    let app = launchApp(session: host.cookie)
    app.buttons["tab-matches"].tap()
    let position = app.staticTexts["match-position"]
    XCTAssertTrue(position.waitForExistence(timeout: 30))
    wait(for: position, toBe: "label == '1 of 1 that fits'", "The matches did not load")
    XCTAssertTrue(app.staticTexts["For " + place].exists)
    XCTAssertTrue(matchCard("Sam Seeker", in: app).exists)
    XCTAssertTrue(app.staticTexts["Why your place fits"].exists)
    XCTAssertTrue(app.staticTexts["Your rent is inside Sam's $1,000 budget"].exists)
    attach(app, "Matches: a person who fits")
    app.buttons["Message Sam"].tap()
    XCTAssertTrue(
      app.navigationBars["Sam Seeker"].waitForExistence(timeout: 30),
      "Messaging should open the conversation in the Inbox")
  }
  @MainActor func testAProfileShowsSomeonesPlaceStartsAConversationAndCanBlock() throws {
    continueAfterFailure = false
    let seeker = try seedMember(name: "Sam Seeker")
    let spot = freshSpot()
    try seedSearch(for: seeker, around: spot)
    let place = try seedListing(for: try seedMember(name: "Jamie Host"), price: 700, at: spot)
    let app = launchApp(session: seeker.cookie)
    app.buttons["tab-matches"].tap()
    let position = app.staticTexts["match-position"]
    XCTAssertTrue(position.waitForExistence(timeout: 30))
    wait(for: position, toBe: "label == '1 of 1 that fits'", "The matches did not load")
    matchCard("Jamie Host", in: app).tap()

    XCTAssertTrue(
      app.staticTexts["Jamie's place"].waitForExistence(timeout: 30), "The profile did not load")
    XCTAssertTrue(app.staticTexts["Jamie Host"].exists)
    XCTAssertTrue(app.staticTexts["ID not checked"].exists)
    XCTAssertTrue(app.staticTexts["Subleasing a place"].exists)
    XCTAssertTrue(labelled(beginning: "Member since ", in: app).exists)
    XCTAssertTrue(labelled(containing: "reviews yet", in: app).exists)
    XCTAssertTrue(labelled(containing: "as subleaser", in: app).exists)
    XCTAssertTrue(labelled(containing: "as subtenant", in: app).exists)
    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", place)).firstMatch.exists)
    XCTAssertTrue(app.staticTexts["No reviews yet."].exists)
    attach(app, "Profile: someone subleasing a place")

    app.buttons["Message Jamie"].tap()
    XCTAssertTrue(
      app.navigationBars["Jamie Host"].waitForExistence(timeout: 30),
      "Messaging from a profile should open the conversation in the Inbox")

    // The profile is still open under Matches. Blocking hides it.
    app.buttons["tab-matches"].tap()
    let more = app.buttons["More: block or report"]
    XCTAssertTrue(more.waitForExistence(timeout: 30))
    more.tap()
    let block = app.buttons["Block member"]
    XCTAssertTrue(block.waitForExistence(timeout: 30))
    block.tap()
    let confirm = app.buttons["Block"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 30))
    confirm.tap()
    XCTAssertTrue(
      labelled(containing: "are hidden while you are signed in", in: app)
        .waitForExistence(timeout: 30), "Blocking did not hide the profile")
    XCTAssertFalse(app.buttons["Message Jamie"].exists)
  }
  @MainActor func testSomeoneLookingIsMessagedByOfferingAPlaceThatFits() throws {
    continueAfterFailure = false
    let spot = freshSpot()
    let host = try seedMember(name: "Harper Host")
    _ = try seedListing(for: host, price: 800, at: spot)
    try seedSearch(for: try seedMember(name: "Sam Seeker"), around: spot)
    let app = launchApp(session: host.cookie)
    app.buttons["tab-matches"].tap()
    let position = app.staticTexts["match-position"]
    XCTAssertTrue(position.waitForExistence(timeout: 30))
    wait(for: position, toBe: "label == '1 of 1 that fits'", "The matches did not load")
    matchCard("Sam Seeker", in: app).tap()
    let about = app.buttons["About Sam Seeker"]
    XCTAssertTrue(about.waitForExistence(timeout: 30))
    reveal(about, in: app)
    about.tap()

    XCTAssertTrue(
      app.staticTexts["What Sam is looking for"].waitForExistence(timeout: 30),
      "The profile did not load")
    XCTAssertTrue(app.staticTexts["Looking for a place"].exists)
    XCTAssertTrue(labelled(containing: "up to $1,000 / month", in: app).exists)
    attach(app, "Profile: someone looking for a place")
    // Harper's one place fits Sam's search, so there is nothing to choose between.
    let message = app.buttons["Message Sam"]
    XCTAssertTrue(message.waitForExistence(timeout: 30))
    message.tap()
    XCTAssertTrue(
      app.navigationBars["Sam Seeker"].waitForExistence(timeout: 30),
      "Offering a place from a profile should open the conversation in the Inbox")
  }
  @MainActor func testYourOwnProfileOpensFromYouWithNothingToMessage() throws {
    continueAfterFailure = false
    let member = try seedMember(name: "Avery Own")
    let app = launchApp(session: member.cookie)
    app.buttons["tab-you"].tap()
    let open = app.buttons["See your public profile"]
    XCTAssertTrue(open.waitForExistence(timeout: 30))
    open.tap()
    XCTAssertTrue(
      app.staticTexts["This is your profile as other people see it."]
        .waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["No reviews yet."].waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["Avery Own"].exists)
    XCTAssertFalse(app.buttons["Message Avery"].exists)
    XCTAssertFalse(app.buttons["More: block or report"].exists)
    XCTAssertFalse(
      app.descendants(matching: .any).matching(identifier: "person-message-unavailable")
        .firstMatch.exists, "Nobody needs telling why they cannot message themselves")
    attach(app, "Profile: your own")
  }
  @MainActor func testSavingOrMessagingAMatchMovesTheDeckOn() throws {
    continueAfterFailure = false
    let seeker = try seedMember(name: "Sam Seeker")
    let spot = freshSpot()
    try seedSearch(for: seeker, around: spot)
    let first = try seedListing(
      for: try seedMember(name: "Jamie Host"), price: 700, at: spot)
    let second = try seedListing(
      for: try seedMember(name: "Riley Host"), price: 800, at: spot)
    let app = launchApp(session: seeker.cookie)
    app.buttons["tab-matches"].tap()
    XCTAssertTrue(matchCard(first, in: app).waitForExistence(timeout: 30))
    app.buttons["Save for later"].tap()
    XCTAssertTrue(matchCard(second, in: app).waitForExistence(timeout: 30))
    XCTAssertEqual(
      app.staticTexts["match-notice"].label, "Saved. It is under Saved posts in You.")

    app.buttons["Message Riley"].tap()
    XCTAssertTrue(
      app.navigationBars["Riley Host"].waitForExistence(timeout: 30),
      "Messaging should open the conversation in the Inbox")
    app.buttons["tab-matches"].tap()
    XCTAssertTrue(app.staticTexts["You've seen all 2"].waitForExistence(timeout: 30))

    // What was seen is remembered when the app is opened again.
    app.terminate()
    let again = launchApp(session: seeker.cookie)
    again.buttons["tab-matches"].tap()
    XCTAssertTrue(again.staticTexts["You've seen all 2"].waitForExistence(timeout: 30))
  }
  @MainActor func testMatchesWithoutAPlanOfferBothWaysToStart() throws {
    continueAfterFailure = false
    let member = try seedMember()
    let app = launchApp(session: member.cookie)
    app.buttons["tab-matches"].tap()
    XCTAssertTrue(app.staticTexts["Matches start with your plans"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.buttons["Sublease my place"].exists)
    attach(app, "Matches: no plans yet")
    app.buttons["Say what I'm looking for"].tap()
    XCTAssertTrue(app.navigationBars["Housing search"].waitForExistence(timeout: 30))
  }
  @MainActor func testListingCommentPostsAndEdits() throws {
    continueAfterFailure = false
    let member = try seedMember()
    let title = try seedListing(for: member)
    let app = launchApp(session: member.cookie)
    openOwnListing(title, in: app)
    app.buttons["View listing"].tap()
    let comment = app.descendants(matching: .any).matching(identifier: "comment-draft").firstMatch
    reveal(comment, in: app)
    let initialComment = "Synthetic public comment"
    enter(initialComment, into: comment, in: app)
    reveal(app.buttons["Post"], in: app)
    app.buttons["Post"].tap()
    XCTAssertTrue(app.staticTexts[initialComment].waitForExistence(timeout: 30))
    app.buttons["Edit"].tap()
    reveal(comment, in: app)
    comment.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 60), "Keyboard never appeared")
    // Focusing this multiline field places the caret at the start. Test an explicit insertion.
    comment.typeText("Edited ")
    XCTAssertEqual(comment.value as? String, "Edited " + initialComment)
    reveal(app.buttons["Save comment"], in: app)
    app.buttons["Save comment"].tap()
    XCTAssertTrue(app.staticTexts["Edited " + initialComment].waitForExistence(timeout: 30))
    attach(app, "Edited listing comment")
  }
  @MainActor func testRoomLayoutCaptureExplainsLiDARRequirement() throws {
    continueAfterFailure = false
    let member = try seedMember()
    let title = try seedListing(for: member)
    let app = launchApp(session: member.cookie)
    openOwnListing(title, in: app)
    let layouts = app.buttons["Capture or manage room layouts"]
    reveal(layouts, in: app)
    layouts.tap()
    XCTAssertTrue(
      app.staticTexts["Room scanning needs a LiDAR-equipped iPhone."].waitForExistence(timeout: 30))
    attach(app, "Room capture capability")
  }
  @MainActor func testLocalDeviceCheckDoesNotRequireAccountOrSupportedCamera() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["CUSE_API_URL"] = "http://127.0.0.1:8936"
    app.launch()
    XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 30))
    signOutIfNeeded(app)
    reveal(app.buttons["Device capture check"], in: app)
    app.buttons["Device capture check"].tap()
    XCTAssertTrue(app.navigationBars["Device capture check"].waitForExistence(timeout: 30))
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
    XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 30))
    signOutIfNeeded(app)
    reveal(app.buttons["Data & privacy"], in: app)
    app.buttons["Data & privacy"].tap()
    XCTAssertTrue(app.navigationBars["Data & privacy"].waitForExistence(timeout: 30))
    XCTAssertTrue(
      app.staticTexts["Development preview. Public release and real transactions are not enabled."]
        .exists)
    attach(app, "Privacy notice at largest Dynamic Type")
  }
  /// Types the first two steps of listing a place and leaves the app on the photos step, where
  /// the place exists on the server and is not published.
  @MainActor private func fillPlaceAndDetails(
    title: String, fillNeighborhood: Bool = true, in app: XCUIApplication
  ) {
    XCTAssertTrue(app.staticTexts["Where is your place?"].waitForExistence(timeout: 30))
    if fillNeighborhood { enter("Westcott", into: app.textFields["Neighborhood"], in: app) }
    reveal(app.textFields["Approximate public address"], in: app)
    enter(
      "Near Westcott — synthetic UI test", into: app.textFields["Approximate public address"],
      in: app)
    tapOutsideTheForm("Continue", in: app)
    XCTAssertTrue(app.staticTexts["Tell people about it"].waitForExistence(timeout: 30))
    // A step that is not finished says what is missing, and stops saying it once that changes.
    app.buttons["Continue"].tap()
    let problem = app.staticTexts["flow-problem"]
    XCTAssertTrue(problem.waitForExistence(timeout: 5))
    XCTAssertEqual(problem.label, "Give your place a title.")
    enter(title, into: app.textFields["Listing title"], in: app)
    XCTAssertTrue(problem.waitForNonExistence(timeout: 5), "The message outlived its cause")
    let description = app.descendants(matching: .any).matching(identifier: "listing-description")
      .firstMatch
    reveal(description, in: app)
    enter(
      "Synthetic simulator listing only. This is not an available property.", into: description,
      in: app)
    dismissKeyboard(in: app)
    attach(app, "Listing steps: details")
    tapOutsideTheForm("Continue", in: app)
    XCTAssertTrue(app.staticTexts["Add photos"].waitForExistence(timeout: 30))
    attach(app, "Listing steps: photos")
  }
  /// From the photos step: no photos, no scan (a simulator cannot scan), then publish.
  @MainActor private func skipToChecksAndPublish(in app: XCUIApplication) {
    tapOutsideTheForm("Skip for now", in: app)
    XCTAssertTrue(app.staticTexts["Let people look around"].waitForExistence(timeout: 30))
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "scan-unavailable").firstMatch
        .waitForExistence(timeout: 30), "A simulator should be told that it cannot scan")
    XCTAssertFalse(app.buttons["Scan now"].exists)
    attach(app, "Listing steps: scan unavailable")
    tapOutsideTheForm("Continue", in: app)
    XCTAssertTrue(app.staticTexts["Last step: checks"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["Your ID is not checked yet"].exists)
    XCTAssertTrue(app.staticTexts["Lease not checked yet"].exists)
    attach(app, "Listing steps: checks")
    tapOutsideTheForm("Publish my place", in: app)
    XCTAssertTrue(app.staticTexts["Your place is live"].waitForExistence(timeout: 30))
    XCTAssertTrue(
      app.staticTexts[
        "Publishing did not check your ID or your lease. Staff review those separately."
      ].exists)
  }
  /// For a button in the header or the bottom bar of the listing steps, which never scrolls.
  /// It waits until the button can be pressed: these are disabled while the step is loading
  /// or saving, and a tap on a disabled button does nothing.
  @MainActor private func tapOutsideTheForm(_ label: String, in app: XCUIApplication) {
    dismissKeyboard(in: app)
    let button = app.buttons[label]
    XCTAssertTrue(button.waitForExistence(timeout: 30))
    wait(for: button, toBe: "isEnabled == true", "\(label) stayed disabled")
    button.tap()
  }
  /// Waits for something about an element that the server decides, such as a label that is
  /// empty until its data arrives.
  @MainActor private func wait(
    for element: XCUIElement, toBe condition: String, _ message: String
  ) {
    let met = expectation(for: NSPredicate(format: condition), evaluatedWith: element)
    XCTAssertEqual(XCTWaiter().wait(for: [met], timeout: 30), .completed, message)
  }
  @MainActor private func dismissKeyboard(in app: XCUIApplication) {
    guard app.keyboards.firstMatch.exists else { return }
    let done = app.buttons["dismiss-keyboard"]
    XCTAssertTrue(done.waitForExistence(timeout: 30))
    done.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 30))
  }
  @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    dismissKeyboard(in: app)
    // The floating tab bar can cover controls that XCTest still reports as hittable.
    // Bring the whole control clear of the actual bars before asking XCTest to tap it.
    func safeTop() -> CGFloat {
      // A bar that is hidden, or belongs to a screen underneath a full-screen cover, still
      // exists for XCTest but covers nothing.
      let bar = app.navigationBars.firstMatch
      return bar.exists && bar.isHittable ? bar.frame.maxY + 4 : app.frame.minY
    }
    func safeBottom() -> CGFloat {
      // The listing steps cover the tab bar and keep their own bar at the bottom. Elsewhere the
      // raised Post button is the highest part of the floating tab bar, and a sublease's page
      // has its own price bar there instead.
      let steps = app.otherElements["listing-flow-bar"]
      if steps.exists { return steps.frame.minY - 4 }
      let post = app.buttons["tab-post"]
      if post.exists { return post.frame.minY - 4 }
      let price = app.otherElements["listing-price-bar"]
      return price.exists ? price.frame.minY - 4 : app.frame.maxY
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
    XCTAssertTrue(field.waitForExistence(timeout: 30))
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
    XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 30))
    return app
  }
  /// Creates state directly on the isolated local API so each test drives only its own feature.
  /// It waits for the answer without `await`: a test that is `async` cannot stop cleanly at its
  /// first failure (the test runner exits instead), and then it is not retried either.
  private func post(_ path: String, _ body: [String: Any], cookie: String? = nil) throws
    -> HTTPURLResponse
  {
    var request = URLRequest(url: try XCTUnwrap(URL(string: Self.apiBase + path)))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(Self.apiBase, forHTTPHeaderField: "Origin")
    if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let answer = Answer()
    let answered = DispatchSemaphore(value: 0)
    URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
      answer.data = data ?? Data()
      answer.response = response as? HTTPURLResponse
      answer.error = error
      answered.signal()
    }.resume()
    XCTAssertEqual(answered.wait(timeout: .now() + 60), .success, "\(path) did not answer")
    if let error = answer.error { throw error }
    let http = try XCTUnwrap(answer.response)
    XCTAssertTrue(
      (200..<300).contains(http.statusCode),
      "\(path) returned \(http.statusCode): \(String(decoding: answer.data, as: UTF8.self))")
    return http
  }
  /// What the server sent back, handed from the network queue to the waiting test.
  private final class Answer: @unchecked Sendable {
    var data = Data()
    var response: HTTPURLResponse?
    var error: Error?
  }
  private func seedMember(name: String = "Seeded UI Test") throws -> SeededMember {
    let response = try post(
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
  /// A day some days from now, as the server writes days.
  private func day(_ offset: Int) -> String {
    let format = DateFormatter()
    format.calendar = Calendar(identifier: .gregorian)
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(identifier: "America/New_York")
    format.dateFormat = "yyyy-MM-dd"
    return format.string(from: Date().addingTimeInterval(Double(offset) * 86_400))
  }
  private typealias Spot = (lat: Double, lng: Double)
  /// A spot of its own in the service area. Matching goes by area, so a test that counts
  /// matches puts its places where no other test, and no earlier run, has put one. The server
  /// keeps a place's pin to three decimals, so the spot is chosen on that grid.
  private func freshSpot() -> Spot {
    (
      Double(Int.random(in: 43_060...43_120)) / 1000,
      -Double(Int.random(in: 76_050...76_250)) / 1000
    )
  }
  private func seedListing(
    for member: SeededMember, price: Int = 800, at spot: Spot = (43.04, -76.13),
    publish: Bool = true
  ) throws -> String {
    let title = "Seeded listing \(UUID().uuidString.prefix(6))"
    let body: [String: Any] = [
      "title": title, "neighborhood": "Westcott", "address": "Approximate synthetic test area",
      "price": price, "beds": 1, "baths": 1, "roomType": "Private room",
      "startDate": day(30), "endDate": day(180),
      "description": "Synthetic simulator listing only. This is not an available property.",
      "amenities": [String](), "images": [String](), "lat": spot.lat, "lng": spot.lng,
      "publish": publish,
    ]
    _ = try post("/api/listings", body, cookie: member.cookie)
    return title
  }
  /// An active housing search that a seeded listing at `spot` fits: its one small area
  /// surrounds the spot, its dates sit inside the listing's and its budget is above the rent.
  private func seedSearch(for member: SeededMember, around spot: Spot) throws {
    let reach = 0.0004
    let body: [String: Any] = [
      "startDate": day(40), "endDate": day(120), "maxBudget": 1000, "roomType": "Any",
      "requiredAmenities": [String](), "preferredAmenities": [String](),
      "introduction": "Synthetic simulator search only.", "status": "active",
      "areas": [
        [
          "id": "seeded", "label": "Westcott",
          "points": [
            ["lat": spot.lat - reach, "lng": spot.lng - reach],
            ["lat": spot.lat + reach, "lng": spot.lng - reach],
            ["lat": spot.lat + reach, "lng": spot.lng + reach],
            ["lat": spot.lat - reach, "lng": spot.lng + reach],
          ],
        ]
      ],
    ]
    _ = try post("/api/my-search", body, cookie: member.cookie)
  }
  /// Anything on screen whose label contains, or begins with, `text`.
  @MainActor private func labelled(containing text: String, in app: XCUIApplication)
    -> XCUIElement
  {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
      .firstMatch
  }
  @MainActor private func labelled(beginning text: String, in app: XCUIApplication)
    -> XCUIElement
  {
    app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text))
      .firstMatch
  }
  /// The card on the Matches screen whose label mentions `text`.
  @MainActor private func matchCard(_ text: String, in app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
  }
  @MainActor private func openOwnListing(_ title: String, in app: XCUIApplication) {
    app.buttons["tab-you"].tap()
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 30), "Seeded listing missing from Your places")
    reveal(row, in: app)
    row.tap()
    XCTAssertTrue(app.buttons["View listing"].waitForExistence(timeout: 30))
  }
  @MainActor private func signOutIfNeeded(_ app: XCUIApplication) {
    app.buttons["tab-you"].tap()
    // An earlier test may have left a session saved. Until the app has checked it, the app
    // does not yet know whether anyone is signed in, and neither does this.
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "checking-session").firstMatch
        .waitForNonExistence(timeout: 30), "The saved session was never checked")
    if app.buttons["Log in or create an account"].waitForExistence(timeout: 3) { return }
    logOut(in: app)
  }
  /// Logs out from the You tab and waits until the app is a guest again. The app goes back to
  /// the Home tab once the server has answered, so returning to You before that is undone.
  /// The Log out row itself is no signal: it stops existing whenever its list scrolls it away.
  @MainActor private func logOut(in app: XCUIApplication) {
    let logout = app.buttons["Log out"]
    reveal(logout, in: app)
    logout.tap()
    wait(for: app.buttons["tab-home"], toBe: "isSelected == true", "Logging out never finished")
    app.buttons["tab-you"].tap()
    XCTAssertTrue(app.buttons["Log in or create an account"].waitForExistence(timeout: 30))
  }
  @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
    let a = XCTAttachment(screenshot: app.screenshot())
    a.name = name
    a.lifetime = .keepAlways
    add(a)
  }
}
