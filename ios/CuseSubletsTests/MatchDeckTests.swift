import XCTest

@testable import CuseSublets

final class MatchDeckTests: XCTestCase {
  // MARK: The deck

  func testADeckStartsOnTheBestMatch() {
    let deck = MatchDeck(ids: ["a", "b", "c"])
    XCTAssertEqual(deck.current, "a")
    XCTAssertEqual(deck.total, 3)
    XCTAssertEqual(MatchText.position(deck), "1 of 3 that fit")
    XCTAssertFalse(deck.canGoBack)
    XCTAssertFalse(deck.isFinished)
  }

  func testMovingOnShowsTheNextOne() {
    var deck = MatchDeck(ids: ["a", "b", "c"])
    deck.moveOn()
    XCTAssertEqual(deck.current, "b")
    XCTAssertEqual(MatchText.position(deck), "2 of 3 that fit")
    XCTAssertTrue(deck.canGoBack)
  }

  func testGoingBackReturnsToTheOneJustLeft() {
    var deck = MatchDeck(ids: ["a", "b", "c"])
    deck.moveOn()
    deck.moveOn()
    deck.goBack()
    XCTAssertEqual(deck.current, "b")
    deck.goBack()
    deck.goBack()
    XCTAssertEqual(deck.current, "a", "Going back past the first one changes nothing")
  }

  func testADeckIsFinishedOnceEveryMatchHasBeenSeen() {
    var deck = MatchDeck(ids: ["a", "b"])
    deck.moveOn()
    deck.moveOn()
    XCTAssertNil(deck.current)
    XCTAssertTrue(deck.isFinished)
    deck.moveOn()
    XCTAssertEqual(deck.seen, ["a", "b"], "Moving on from the end changes nothing")
    deck.startAgain()
    XCTAssertEqual(deck.current, "a")
    XCTAssertFalse(deck.isFinished)
  }

  func testAFinishedDeckHasNoPositionToShow() {
    var deck = MatchDeck(ids: ["a", "b"])
    deck.moveOn()
    deck.moveOn()
    XCTAssertEqual(MatchText.position(deck), "")
  }

  func testAnEmptyDeckIsNotFinished() {
    let deck = MatchDeck(ids: [])
    XCTAssertNil(deck.current)
    XCTAssertFalse(deck.isFinished)
  }

  func testADeckResumesAfterTheOnesAlreadySeen() {
    let deck = MatchDeck(ids: ["a", "b", "c"], seen: ["a"])
    XCTAssertEqual(deck.current, "b")
    XCTAssertEqual(MatchText.position(deck), "2 of 3 that fit")
  }

  func testSeenMatchesThatNoLongerFitAreForgotten() {
    let deck = MatchDeck(ids: ["b", "c"], seen: ["a", "b", "gone"])
    XCTAssertEqual(deck.seen, ["b"])
    XCTAssertEqual(deck.current, "c")
    XCTAssertEqual(MatchText.position(deck), "2 of 2 that fit")
  }

  func testOneMatchIsCountedInTheSingular() {
    XCTAssertEqual(MatchText.position(MatchDeck(ids: ["a"])), "1 of 1 that fits")
    XCTAssertEqual(MatchText.position(MatchDeck(ids: [])), "")
  }

  // MARK: Remembering what was seen

  func testSeenMatchesAreKeptPerPersonAndPerPlan() throws {
    let name = "match-seen-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = MatchSeenStore(defaults: defaults)
    store.save(["a", "b"], user: "u1", plan: "search:s1")
    XCTAssertEqual(store.seen(user: "u1", plan: "search:s1"), ["a", "b"])
    XCTAssertEqual(store.seen(user: "u1", plan: "listing:l1"), [])
    XCTAssertEqual(store.seen(user: "u2", plan: "search:s1"), [])
    store.save([], user: "u1", plan: "search:s1")
    XCTAssertEqual(store.seen(user: "u1", plan: "search:s1"), [])
  }

  func testForgettingAPersonRemovesOnlyTheirSeenMatches() throws {
    let name = "match-seen-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = MatchSeenStore(defaults: defaults)
    store.save(["a"], user: "u1", plan: "search:s1")
    store.save(["b"], user: "u1", plan: "listing:l1")
    store.save(["c"], user: "u10", plan: "search:s2")
    defaults.set("kept", forKey: "something.else")
    store.forget(user: "u1")
    XCTAssertEqual(store.seen(user: "u1", plan: "search:s1"), [])
    XCTAssertEqual(store.seen(user: "u1", plan: "listing:l1"), [])
    XCTAssertEqual(store.seen(user: "u10", plan: "search:s2"), ["c"])
    XCTAssertEqual(defaults.string(forKey: "something.else"), "kept")
  }

  // MARK: Swiping

  func testAShortDragDoesNothing() {
    XCTAssertNil(MatchSwipe.choice(translation: 60, width: 390))
    XCTAssertNil(MatchSwipe.choice(translation: -60, width: 390))
  }

  func testALongDragLeftPassesAndRightSaves() {
    XCTAssertEqual(MatchSwipe.choice(translation: -140, width: 390), .pass)
    XCTAssertEqual(MatchSwipe.choice(translation: 140, width: 390), .save)
  }

  // MARK: Words

  private func listing() -> Listing {
    Listing(
      id: "listing", ownerId: "host", title: "Sunny place", neighborhood: "Westcott",
      address: "Near campus", lat: 43, lng: -76.1, price: 950, beds: 2, baths: 1,
      roomType: "Entire place", startDate: "2027-01-01", endDate: "2027-06-01",
      description: "Synthetic", amenities: ["Furnished", "laundry ", "Parking"], images: [],
      status: "approved", leaseStatus: "pending", permissionStatus: "pending",
      hostName: "Host Person", hostIdentity: "verified", sample: true)
  }

  private func search() -> HousingSearch {
    HousingSearch(
      id: "search", ownerId: "seeker", ownerName: "Jamie Chen", ownerIdentity: "pending",
      status: "active", startDate: "2027-01-05", endDate: "2027-05-15", minBudget: 700,
      maxBudget: 1000, minBedrooms: 2, roomType: "Entire place",
      requiredAmenities: ["Laundry"], preferredAmenities: ["Furnished", "Parking", "Gym"],
      areas: [
        .init(
          id: "far", label: "Downtown",
          points: [
            .init(lat: 43.04, lng: -76.16), .init(lat: 43.06, lng: -76.16),
            .init(lat: 43.06, lng: -76.14),
          ]),
        .init(
          id: "near", label: "Westcott",
          points: [
            .init(lat: 42.99, lng: -76.11), .init(lat: 43.01, lng: -76.11),
            .init(lat: 43.01, lng: -76.09), .init(lat: 42.99, lng: -76.09),
          ]),
      ], introduction: "A quiet place")
  }

  func testReasonsForSomeoneLookingSayWhatFitsTheirSearch() {
    XCTAssertEqual(
      MatchText.reasons(listing: listing(), search: search(), for: .seeker),
      [
        "Inside your $1,000 budget",
        "Covers Jan 5 – May 15",
        "In your Westcott area",
        "An entire place, as you asked",
        "At least 2 bedrooms, as you asked",
        "Has what you need: Laundry",
        "Also has Furnished and Parking, which you'd like",
      ])
  }

  func testReasonsForSomeoneSubleasingSayWhyTheirPlaceFitsThePerson() {
    XCTAssertEqual(
      MatchText.reasons(listing: listing(), search: search(), for: .host(seeker: "Jamie Chen")),
      [
        "Your rent is inside Jamie's $1,000 budget",
        "Your dates cover Jan 5 – May 15",
        "Your place is in Jamie's Westcott area",
        "Jamie wants an entire place",
        "Jamie needs at least 2 bedrooms",
        "Your place has what Jamie needs: Laundry",
        "It also has Furnished and Parking, which Jamie would like",
      ])
  }

  func testReasonsLeaveOutWhatThePersonDidNotAskFor() {
    var open = search()
    open.roomType = "Any"
    open.minBedrooms = nil
    open.requiredAmenities = []
    open.preferredAmenities = ["Gym"]
    XCTAssertEqual(
      MatchText.reasons(listing: listing(), search: open, for: .seeker),
      ["Inside your $1,000 budget", "Covers Jan 5 – May 15", "In your Westcott area"])
  }

  func testAPrivateRoomIsWordedAsOne() {
    var room = search()
    room.roomType = "Private room"
    XCTAssertTrue(
      MatchText.reasons(listing: listing(), search: room, for: .seeker)
        .contains("A private room, as you asked"))
  }

  func testChecksLineSaysWhatIsAndIsNotChecked() {
    XCTAssertEqual(
      MatchText.checks(identity: "verified", lease: "verified"),
      "ID checked · lease checked by staff")
    XCTAssertEqual(
      MatchText.checks(identity: "verified", lease: "pending"), "ID checked · lease not checked")
    XCTAssertEqual(
      MatchText.checks(identity: "needs_info", lease: "pending"),
      "ID not checked · lease not checked")
  }

  func testListsReadNaturally() {
    XCTAssertEqual(MatchText.list(["Laundry"]), "Laundry")
    XCTAssertEqual(MatchText.list(["Laundry", "Gym"]), "Laundry and Gym")
    XCTAssertEqual(MatchText.list(["Laundry", "Gym", "Parking"]), "Laundry, Gym and Parking")
  }

  func testThePlanChipSaysWhoseMatchesTheseAre() {
    XCTAssertEqual(MatchText.planLabel(search: true, title: ""), "For your search")
    XCTAssertEqual(MatchText.planLabel(search: false, title: "Sunny place"), "For Sunny place")
  }
}
