import XCTest

@testable import CuseSublets

final class SearchStepsTests: XCTestCase {
  /// 18 November 2026 in Syracuse.
  private var today: Date { parseDay("2026-11-18") }

  // MARK: Steps

  func testThereAreThreeStepsAndEachSaysWhereYouAre() {
    XCTAssertEqual(SearchStep.allCases.map(\.progress), [
      "Step 1 of 3 · Dates and budget", "Step 2 of 3 · The place", "Step 3 of 3 · About you",
    ])
    XCTAssertEqual(SearchStep.dates.title, "When do you need a place?")
    XCTAssertEqual(SearchStep.place.title, "What are you looking for?")
    XCTAssertEqual(SearchStep.about.title, "A little about you")
  }

  // MARK: Terms

  func testATermFillsInTheNextDatesThatHaveNotStarted() {
    XCTAssertEqual(days(SearchTerm.spring.dates(from: today)), ["2027-01-05", "2027-05-15"])
    XCTAssertEqual(days(SearchTerm.summer.dates(from: today)), ["2027-05-15", "2027-08-15"])
    // This fall is already under way in November, so it means the next one.
    XCTAssertEqual(days(SearchTerm.fall.dates(from: today)), ["2027-08-15", "2027-12-20"])
    XCTAssertEqual(days(SearchTerm.fullYear.dates(from: today)), ["2027-08-15", "2028-08-14"])
    // A term that starts today still counts as this year's.
    XCTAssertEqual(
      days(SearchTerm.spring.dates(from: parseDay("2027-01-05"))), ["2027-01-05", "2027-05-15"])
  }

  func testANewSearchStartsOnTheTermThatComesNext() {
    let form = SearchForm(today: today)
    XCTAssertEqual([isoDay(form.start), isoDay(form.end)], ["2027-01-05", "2027-05-15"])
    XCTAssertEqual(form.term(today: today), .spring)
    XCTAssertEqual(form.budget, 1000)
    XCTAssertEqual(form.kind, "Any")
  }

  func testDatesChangedByHandMatchNoTerm() {
    var form = SearchForm(today: today)
    form.end = parseDay("2027-05-20")
    XCTAssertNil(form.term(today: today))
  }

  // MARK: Where

  func testAnywhereIsOneAreaInsideTheServiceArea() {
    let area = SearchForm.anywhere
    XCTAssertEqual(area.label, "Anywhere in Syracuse")
    XCTAssertEqual(area.points.count, 4)
    for point in area.points {
      XCTAssertTrue((42.9...43.15).contains(point.lat), "\(point.lat)")
      XCTAssertTrue((-76.3...(-75.95)).contains(point.lng), "\(point.lng)")
    }
    XCTAssertTrue(area.contains(.init(lat: 43.04, lng: -76.13)))
  }

  func testChoosingAnywhereReplacesDrawnAreasAndDrawingOneReplacesAnywhere() {
    var form = SearchForm(today: today)
    form.add(area: westcott)
    XCTAssertFalse(form.isAnywhere)
    form.chooseAnywhere()
    XCTAssertTrue(form.isAnywhere)
    XCTAssertEqual(form.areas.map(\.label), ["Anywhere in Syracuse"])
    form.add(area: westcott)
    XCTAssertEqual(form.areas.map(\.label), ["Westcott"])
    form.remove(areaID: westcott.id)
    XCTAssertEqual(form.areas.count, 0)
  }

  func testNoMoreThanFiveAreasAreKept() {
    var form = SearchForm(today: today)
    for n in 1...6 {
      form.add(area: .init(id: "a\(n)", label: "Area \(n)", points: westcott.points))
    }
    XCTAssertEqual(form.areas.count, 5)
    XCTAssertFalse(form.canAddArea)
  }

  // MARK: Must-haves

  func testMustHavesAreTheSameWordsAPlaceIsListedWith() {
    var form = SearchForm(today: today)
    XCTAssertEqual(form.mustHaveChoices, ListingForm.commonAmenities)
    form.toggle(mustHave: "Parking")
    form.toggle(mustHave: "Furnished")
    form.toggle(mustHave: "Parking")
    XCTAssertEqual(form.mustHaves, ["Furnished"])
  }

  // MARK: Moving on

  func testEachStepSaysWhatIsMissing() {
    var form = SearchForm(today: today)
    XCTAssertNil(form.problem(for: .dates, today: today))
    form.end = form.start
    XCTAssertEqual(form.problem(for: .dates, today: today), "Move out has to be after move in.")
    form.start = parseDay("2026-01-05")
    form.end = parseDay("2026-05-15")
    XCTAssertEqual(form.problem(for: .dates, today: today), "Move out has to be in the future.")

    XCTAssertEqual(
      form.problem(for: .place, today: today),
      "Say where: anywhere in Syracuse, or draw an area on the map.")
    form.chooseAnywhere()
    XCTAssertNil(form.problem(for: .place, today: today))

    XCTAssertNil(form.problem(for: .about, today: today))
    form.introduction = String(repeating: "a", count: 501)
    XCTAssertEqual(form.problem(for: .about, today: today), "Keep it to 500 characters.")
  }

  // MARK: Saving

  func testWhatIsSentIsWhatTheServerExpects() throws {
    var form = SearchForm(today: today)
    form.budget = 950
    form.kind = "Private room"
    form.chooseAnywhere()
    form.toggle(mustHave: "Furnished")
    form.introduction = "  Junior in mechanical engineering.  "
    let body = form.payload(active: true)
    XCTAssertEqual(body["startDate"] as? String, "2027-01-05")
    XCTAssertEqual(body["endDate"] as? String, "2027-05-15")
    XCTAssertEqual(body["maxBudget"] as? Double, 950)
    XCTAssertNil(body["minBudget"])
    XCTAssertNil(body["minBedrooms"])
    XCTAssertEqual(body["roomType"] as? String, "Private room")
    XCTAssertEqual(body["requiredAmenities"] as? [String], ["Furnished"])
    XCTAssertEqual(body["preferredAmenities"] as? [String], [])
    XCTAssertEqual(body["introduction"] as? String, "Junior in mechanical engineering.")
    XCTAssertEqual(body["status"] as? String, "active")
    XCTAssertEqual((body["areas"] as? [[String: Any]])?.first?["label"] as? String, "Anywhere in Syracuse")
    XCTAssertEqual(form.payload(active: false)["status"] as? String, "paused")
    XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
  }

  func testAnExistingSearchKeepsWhatTheStepsDoNotEdit() {
    var form = SearchForm(search: search(min: 600, max: 1200, kind: "Entire place", bedrooms: 2))
    XCTAssertEqual(form.budget, 1200)
    XCTAssertEqual(form.areas.map(\.label), ["Westcott"])
    XCTAssertEqual(form.mustHaves, ["Parking"])
    var body = form.payload(active: true)
    XCTAssertEqual(body["minBudget"] as? Double, 600)
    XCTAssertEqual(body["minBedrooms"] as? Double, 2)
    XCTAssertEqual(body["preferredAmenities"] as? [String], ["Gym"])
    // A lowest rent above the new most-I-can-spend would be refused, so it is dropped. A
    // bedroom count only means something for an entire place.
    form.budget = 500
    form.kind = "Private room"
    body = form.payload(active: true)
    XCTAssertNil(body["minBudget"])
    XCTAssertNil(body["minBedrooms"])
  }

  func testAnUnfinishedSearchSavedElsewhereIsPickedUp() {
    var form = SearchForm(today: today)
    form.apply(draft: [
      "startDate": "2027-02-01", "endDate": "2027-06-30", "maxBudget": "1250", "minBudget": "",
      "roomType": "Entire place", "requiredAmenities": ["Laundry"], "introduction": "Hello",
      "areas": [
        [
          "id": "w", "label": "Westcott",
          "points": [
            ["lat": 43.03, "lng": -76.13], ["lat": 43.05, "lng": -76.13],
            ["lat": 43.05, "lng": -76.11],
          ],
        ]
      ],
    ])
    XCTAssertEqual([isoDay(form.start), isoDay(form.end)], ["2027-02-01", "2027-06-30"])
    XCTAssertEqual(form.budget, 1250)
    XCTAssertEqual(form.kind, "Entire place")
    XCTAssertEqual(form.mustHaves, ["Laundry"])
    XCTAssertEqual(form.introduction, "Hello")
    XCTAssertEqual(form.areas.map(\.label), ["Westcott"])
    // Whatever a draft leaves out or leaves blank keeps its starting answer.
    var untouched = SearchForm(today: today)
    untouched.apply(draft: ["maxBudget": "", "roomType": "Shared", "startDate": ""])
    XCTAssertEqual(untouched, SearchForm(today: today))
  }

  func testTheBudgetSliderReachesAnExistingBudgetOutsideItsUsualRange() {
    XCTAssertEqual(SearchForm(today: today).budgetBounds, 300...3000)
    XCTAssertEqual(SearchForm(search: search(max: 4500)).budgetBounds, 300...4500)
  }

  // MARK: How many fit

  func testTheCountIsOfPlacesThatFitWhatHasBeenAnsweredSoFar() {
    var form = SearchForm(today: today)
    let places = [
      place("a", price: 900), place("b", price: 1400), place("c", price: 800, kind: "Entire place"),
      place("mine", owner: "me", price: 700),
      place("short", price: 700, end: "2027-03-01"),
    ]
    // Before anywhere is chosen the whole service area counts.
    XCTAssertEqual(form.fits(places, viewerID: "me", today: "2026-11-18"), 2)
    form.kind = "Private room"
    XCTAssertEqual(form.fits(places, viewerID: "me", today: "2026-11-18"), 1)
    form.budget = 1500
    XCTAssertEqual(form.fits(places, viewerID: "me", today: "2026-11-18"), 2)
    form.toggle(mustHave: "Parking")
    XCTAssertEqual(form.fits(places, viewerID: "me", today: "2026-11-18"), 0)
  }

  func testTheCountIsSaidInWords() {
    XCTAssertEqual(SearchText.fits(14), "14 places fit so far")
    XCTAssertEqual(SearchText.fits(1), "1 place fits so far")
    XCTAssertEqual(SearchText.fits(0), "No places fit yet")
    XCTAssertEqual(SearchText.fitsNow(5), "5 places fit right now")
    XCTAssertEqual(SearchText.fitsNow(1), "1 place fits right now")
    XCTAssertEqual(SearchText.fitsNow(0), "No places fit right now")
  }

  // MARK: The summary

  func testASearchIsSummedUpRowByRow() {
    let rows = SearchText.rows(search(min: nil, max: 1000, kind: "Private room"))
    XCTAssertEqual(rows.map(\.title), ["Dates", "Budget", "Kind of place", "Where", "Must-haves", "About you"])
    XCTAssertEqual(rows.map(\.value), [
      "Jan 5 – May 15", "Up to $1,000 a month", "Private room", "Westcott", "Parking",
      "Quiet, non-smoker.",
    ])
    XCTAssertEqual(rows.map(\.step), [.dates, .dates, .place, .place, .place, .about])
  }

  func testTheSummarySaysWhenSomethingIsLeftOpen() {
    var s = search(min: 600, max: 1200, kind: "Any")
    s.requiredAmenities = []
    s.introduction = " "
    let rows = SearchText.rows(s)
    XCTAssertEqual(rows[1].value, "$600 to $1,200 a month")
    XCTAssertEqual(rows[2].value, "Either a room or an entire place")
    XCTAssertEqual(rows[4].value, "None")
    XCTAssertEqual(rows[5].value, "Nothing yet")
    XCTAssertEqual(
      SearchText.rows(search(max: 1500, kind: "Entire place", bedrooms: 2))[2].value,
      "Entire place · 2 or more bedrooms")
  }

  // MARK: Fixtures

  private func days(_ dates: (start: Date, end: Date)) -> [String] {
    [isoDay(dates.start), isoDay(dates.end)]
  }

  private var westcott: SearchArea {
    .init(
      id: "w", label: "Westcott",
      points: [
        .init(lat: 43.03, lng: -76.13), .init(lat: 43.05, lng: -76.13),
        .init(lat: 43.05, lng: -76.11), .init(lat: 43.03, lng: -76.11),
      ])
  }

  private func search(
    min: Double? = nil, max: Double = 1000, kind: String = "Any", bedrooms: Double? = nil
  ) -> HousingSearch {
    HousingSearch(
      id: "s", ownerId: "me", ownerName: "Alex Morgan", ownerIdentity: "pending",
      status: "active", startDate: "2027-01-05", endDate: "2027-05-15", minBudget: min,
      maxBudget: max, minBedrooms: bedrooms, roomType: kind, requiredAmenities: ["Parking"],
      preferredAmenities: ["Gym"], areas: [westcott], introduction: "Quiet, non-smoker.",
      createdAt: nil)
  }

  private func place(
    _ id: String, owner: String = "host", price: Double, kind: String = "Private room",
    end: String = "2027-06-01"
  ) -> Listing {
    Listing(
      id: id, ownerId: owner, title: id, neighborhood: "Westcott", address: "", lat: 43.04,
      lng: -76.13, price: price, beds: 1, baths: 1, roomType: kind, startDate: "2027-01-01",
      endDate: end, description: "", amenities: ["Furnished"], images: [], videoUrl: nil,
      matterportUrl: nil, status: "approved", leaseStatus: "pending",
      permissionStatus: "pending", hostName: "Host", hostIdentity: "pending", sample: false,
      createdAt: nil)
  }
}
