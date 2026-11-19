import XCTest

@testable import CuseSublets

final class PersonProfileTests: XCTestCase {
  // MARK: Words

  func testMemberSinceNamesTheMonthTheServerGives() {
    XCTAssertEqual(PersonText.memberSince("2026-09"), "Member since September 2026")
    // An older server sends the whole moment.
    XCTAssertEqual(
      PersonText.memberSince("2026-01-31T23:30:00.000Z"), "Member since January 2026")
  }

  func testMemberSinceSaysNothingWhenTheDateIsUnknown() {
    XCTAssertNil(PersonText.memberSince(nil))
    XCTAssertNil(PersonText.memberSince(""))
    XCTAssertNil(PersonText.memberSince("2026-13"))
    XCTAssertNil(PersonText.memberSince("soon"))
  }

  func testRatingIsTheAverageToOneDecimal() {
    XCTAssertEqual(
      PersonText.rating([5, 5, 4]), .init(value: "4.7", caption: "from 3 reviews"))
    XCTAssertEqual(PersonText.rating([5]), .init(value: "5.0", caption: "from 1 review"))
  }

  func testNoReviewsMeansNoRating() {
    XCTAssertNil(PersonText.rating([]))
  }

  func testRolesSayWhatSomeoneIsDoingHereNow() {
    XCTAssertEqual(PersonText.roles(places: 1, looking: false), ["Subleasing a place"])
    XCTAssertEqual(PersonText.roles(places: 3, looking: false), ["Subleasing 3 places"])
    XCTAssertEqual(PersonText.roles(places: 0, looking: true), ["Looking for a place"])
    XCTAssertEqual(
      PersonText.roles(places: 1, looking: true), ["Subleasing a place", "Looking for a place"])
    XCTAssertEqual(PersonText.roles(places: 0, looking: false), [])
  }

  func testPlacesHeadingUsesTheFirstName() {
    XCTAssertEqual(PersonText.placesHeading(name: "Jamie Chen", count: 1), "Jamie's place")
    XCTAssertEqual(PersonText.placesHeading(name: "Jamie Chen", count: 2), "Jamie's places")
  }

  func testAReviewSaysWhichSideTheReviewerWasOnAndWhenTheStayEnded() {
    XCTAssertEqual(
      PersonText.reviewer(role: "subtenant", stayEnded: "2026-05"),
      "Subtenant · stay ended May 2026")
    XCTAssertEqual(
      PersonText.reviewer(role: "subleaser", stayEnded: "2026-12"),
      "Subleaser · stay ended December 2026")
  }

  func testAReviewFromAnOlderServerSaysOnlyWhatIsKnown() {
    XCTAssertEqual(PersonText.reviewer(role: nil, stayEnded: "2026-05"), "Stay ended May 2026")
    XCTAssertEqual(PersonText.reviewer(role: "subtenant", stayEnded: nil), "Subtenant")
    XCTAssertEqual(PersonText.reviewer(role: nil, stayEnded: nil), "")
    XCTAssertEqual(PersonText.reviewer(role: "landlord", stayEnded: nil), "")
  }

  func testLookingSummaryGivesTheKindAndTheBudget() {
    XCTAssertEqual(
      PersonText.looking(search(roomType: "Private room")),
      "Private room · up to $1,000 / month")
    XCTAssertEqual(
      PersonText.looking(search(roomType: "Any")), "Any kind of place · up to $1,000 / month")
  }

  // MARK: Messaging. Every conversation is about a place.

  func testSomeoneWithAPlaceCanBeMessagedAboutIt() {
    let choices = PersonMessage.choices(
      viewerID: "me", personID: "host", theirPlaces: [listing(id: "a", title: "Sunny room")],
      theirSearch: nil, myPlaces: [], today: today)
    XCTAssertEqual(
      choices, [.init(listingID: "a", searchID: nil, label: "About Sunny room")])
  }

  func testAGuestCanStartFromSomeonesPlace() {
    let choices = PersonMessage.choices(
      viewerID: nil, personID: "host", theirPlaces: [listing(id: "a", title: "Sunny room")],
      theirSearch: nil, myPlaces: [], today: today)
    XCTAssertEqual(choices.map(\.listingID), ["a"])
  }

  func testSomeoneLookingCanBeOfferedAPlaceOfMineThatFits() {
    let mine = listing(id: "mine", owner: "me", title: "My room")
    let tooDear = listing(id: "dear", owner: "me", title: "Pricey", price: 2000)
    let choices = PersonMessage.choices(
      viewerID: "me", personID: "seeker", theirPlaces: [],
      theirSearch: search(roomType: "Any"), myPlaces: [tooDear, mine], today: today)
    XCTAssertEqual(
      choices, [.init(listingID: "mine", searchID: "search", label: "Offer My room")])
  }

  func testTheirPlacesComeBeforeMyOffers() {
    let choices = PersonMessage.choices(
      viewerID: "me", personID: "seeker",
      theirPlaces: [listing(id: "theirs", owner: "seeker", title: "Their room")],
      theirSearch: search(roomType: "Any"),
      myPlaces: [listing(id: "mine", owner: "me", title: "My room")], today: today)
    XCTAssertEqual(choices.map(\.label), ["About Their room", "Offer My room"])
  }

  func testNobodyMessagesThemselves() {
    let choices = PersonMessage.choices(
      viewerID: "host", personID: "host", theirPlaces: [listing(id: "a", title: "Sunny room")],
      theirSearch: nil, myPlaces: [listing(id: "a", title: "Sunny room")], today: today)
    XCTAssertEqual(choices, [])
  }

  func testWithNothingToMessageAboutTheProfileSaysWhy() {
    XCTAssertEqual(
      PersonMessage.unavailable(name: "Sam Seeker", looking: true),
      "Conversations here are about a place. To message Sam, list a place that fits what they're looking for."
    )
    XCTAssertEqual(
      PersonMessage.unavailable(name: "Sam Seeker", looking: false),
      "Conversations here are about a place. Sam has no place listed and no search open right now."
    )
  }

  // MARK: Older servers

  func testAProfileFromAnOlderServerStillOpens() throws {
    let old = """
      {"profile":{"id":"u","name":"Jamie Chen","identity":"verified","bio":"Hi","photos":[],"socials":{}},
       "listings":[],"search":null,"reviewableBookings":[],
       "reviews":[{"id":"r","authorName":"Alex Morgan","rating":5,"body":"All good here."}]}
      """
    let profile = try JSONDecoder().decode(PublicProfileResponse.self, from: Data(old.utf8))
    XCTAssertNil(profile.profile.joinedAt)
    XCTAssertNil(profile.completed)
    XCTAssertNil(profile.reviews[0].authorRole)
    XCTAssertNil(profile.reviews[0].stayEnded)
  }

  func testAProfileCarriesWhatSomeoneHasFinished() throws {
    let new = """
      {"profile":{"id":"u","name":"Jamie Chen","identity":"verified","bio":"","photos":[],"socials":{},"joinedAt":"2026-09"},
       "listings":[],"search":null,"reviewableBookings":[],"completed":{"subleaser":2,"subtenant":1},
       "reviews":[{"id":"r","authorId":"a","authorName":"Alex Morgan","rating":5,"body":"All good here.",
                   "authorRole":"subtenant","stayEnded":"2026-05","listingTitle":"Sunny room"}]}
      """
    let profile = try JSONDecoder().decode(PublicProfileResponse.self, from: Data(new.utf8))
    XCTAssertEqual(profile.profile.joinedAt, "2026-09")
    XCTAssertEqual(profile.completed?.subleaser, 2)
    XCTAssertEqual(profile.completed?.subtenant, 1)
    XCTAssertEqual(profile.reviews[0].authorId, "a")
    XCTAssertEqual(profile.reviews[0].authorRole, "subtenant")
  }

  // MARK: Samples

  private let today = "2026-11-17"

  private func listing(
    id: String, owner: String = "host", title: String, price: Double = 800
  ) -> Listing {
    Listing(
      id: id, ownerId: owner, title: title, neighborhood: "Westcott", address: "Near campus",
      lat: 43.05, lng: -76.15, price: price, beds: 1, baths: 1, roomType: "Private room",
      startDate: "2027-01-01", endDate: "2027-06-01", description: "Synthetic", amenities: [],
      images: [], status: "approved", leaseStatus: "pending", permissionStatus: "pending",
      hostName: "Host Person", hostIdentity: "verified", sample: true)
  }

  private func search(roomType: String) -> HousingSearch {
    HousingSearch(
      id: "search", ownerId: "seeker", ownerName: "Sam Seeker", ownerIdentity: "pending",
      status: "active", startDate: "2027-01-05", endDate: "2027-05-15", minBudget: nil,
      maxBudget: 1000, minBedrooms: nil, roomType: roomType, requiredAmenities: [],
      preferredAmenities: [],
      areas: [
        .init(
          id: "near", label: "Westcott",
          points: [
            .init(lat: 43.04, lng: -76.16), .init(lat: 43.06, lng: -76.16),
            .init(lat: 43.06, lng: -76.14), .init(lat: 43.04, lng: -76.14),
          ])
      ], introduction: "Synthetic")
  }
}
