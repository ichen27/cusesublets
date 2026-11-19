import Foundation

/// The three steps of saying what you are looking for, in order.
enum SearchStep: Int, CaseIterable {
  case dates, place, about

  var label: String {
    switch self {
    case .dates: return "Dates and budget"
    case .place: return "The place"
    case .about: return "About you"
    }
  }

  var title: String {
    switch self {
    case .dates: return "When do you need a place?"
    case .place: return "What are you looking for?"
    case .about: return "A little about you"
    }
  }

  /// "Step 2 of 3 · The place".
  var progress: String { "Step \(rawValue + 1) of \(Self.allCases.count) · \(label)" }
}

/// A one-tap answer to "when": it fills in the two dates, which can then be changed by hand.
/// The dates are round guesses at a university year, not any one school's calendar.
enum SearchTerm: String, CaseIterable, Identifiable {
  case spring = "Spring semester"
  case summer = "Summer"
  case fall = "Fall"
  case fullYear = "Full year"

  var id: String { rawValue }

  /// Month and day the term starts and ends, and whether it ends in the following year.
  private var span: (start: (Int, Int), end: (Int, Int), endsNextYear: Bool) {
    switch self {
    case .spring: return ((1, 5), (5, 15), false)
    case .summer: return ((5, 15), (8, 15), false)
    case .fall: return ((8, 15), (12, 20), false)
    case .fullYear: return ((8, 15), (8, 14), true)
    }
  }

  /// The next time this term starts, today included, and when it ends.
  func dates(from today: Date) -> (start: Date, end: Date) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = marketplaceTimeZone
    let first = calendar.startOfDay(for: today)
    func day(_ year: Int, _ monthDay: (Int, Int)) -> Date {
      calendar.date(from: DateComponents(year: year, month: monthDay.0, day: monthDay.1)) ?? first
    }
    var year = calendar.component(.year, from: first)
    if day(year, span.start) < first { year += 1 }
    return (day(year, span.start), day(year + (span.endsNextYear ? 1 : 0), span.end))
  }
}

/// What someone has answered about the place they are looking for, and the rules for moving on.
struct SearchForm: Equatable {
  var start: Date
  var end: Date
  /// The most they can spend a month, in dollars.
  var budget = 1000
  /// "Private room", "Entire place" or "Any", as the server stores it.
  var kind = "Any"
  var areas: [SearchArea] = []
  var mustHaves: [String] = []
  var introduction = ""
  // Parts of an existing search that the steps do not ask about. They are sent back unchanged.
  var minBudget: Double?
  var minBedrooms: Double?
  var preferred: [String] = []

  static let budgetStep = 50
  static let areaLimit = 5
  static let introductionLimit = 500
  static let kinds: [(value: String, label: String)] = [
    ("Private room", "Private room"), ("Entire place", "Entire place"), ("Any", "Either"),
  ]

  /// One area covering everything the service covers, for someone who does not mind where.
  /// The server needs at least one area; this one sits just inside its bounds.
  static let anywhere = SearchArea(
    id: "anywhere", label: "Anywhere in Syracuse",
    points: [
      .init(lat: 42.901, lng: -76.299), .init(lat: 43.149, lng: -76.299),
      .init(lat: 43.149, lng: -75.951), .init(lat: 42.901, lng: -75.951),
    ])

  /// A new search starts on whichever term comes next.
  init(today: Date = Date()) {
    let next = [SearchTerm.spring, .summer, .fall].map { $0.dates(from: today) }
      .min { $0.start < $1.start }!
    start = next.start
    end = next.end
  }

  init(search: HousingSearch) {
    start = parseDay(search.startDate)
    end = parseDay(search.endDate)
    budget = Int(search.maxBudget.rounded())
    kind = search.roomType
    areas = search.areas
    mustHaves = search.requiredAmenities
    introduction = search.introduction
    minBudget = search.minBudget
    minBedrooms = search.minBedrooms
    preferred = search.preferredAmenities
  }

  /// Fills in what an unfinished search saved from the website or an older version of the app
  /// holds. Its fields are what was typed, so numbers arrive as text.
  mutating func apply(draft: [String: Any]) {
    if let day = draft["startDate"] as? String, !day.isEmpty { start = parseDay(day) }
    if let day = draft["endDate"] as? String, !day.isEmpty { end = parseDay(day) }
    if let most = (draft["maxBudget"] as? String).flatMap(Double.init)
      ?? (draft["maxBudget"] as? Double), most > 0
    {
      budget = Int(most.rounded())
    }
    if let kind = draft["roomType"] as? String, Self.kinds.contains(where: { $0.value == kind }) {
      self.kind = kind
    }
    if let wanted = draft["requiredAmenities"] as? [String] { mustHaves = wanted }
    if let liked = draft["preferredAmenities"] as? [String] { preferred = liked }
    if let hello = draft["introduction"] as? String { introduction = hello }
    if let drawn = draft["areas"], JSONSerialization.isValidJSONObject(drawn),
      let data = try? JSONSerialization.data(withJSONObject: drawn),
      let areas = try? JSONDecoder().decode([SearchArea].self, from: data)
    {
      self.areas = Array(areas.prefix(Self.areaLimit))
    }
  }

  // MARK: Dates and budget

  /// The term whose dates are the ones chosen, if any.
  func term(today: Date) -> SearchTerm? {
    SearchTerm.allCases.first {
      let dates = $0.dates(from: today)
      return isoDay(dates.start) == isoDay(start) && isoDay(dates.end) == isoDay(end)
    }
  }

  mutating func choose(_ term: SearchTerm, today: Date) {
    (start, end) = term.dates(from: today)
  }

  /// What the budget slider runs between. It stretches to reach a budget set somewhere else.
  var budgetBounds: ClosedRange<Int> { min(300, budget)...max(3000, budget) }

  // MARK: Where

  var isAnywhere: Bool { areas.contains { $0.id == Self.anywhere.id } }
  var canAddArea: Bool { areas.filter { $0.id != Self.anywhere.id }.count < Self.areaLimit }

  mutating func chooseAnywhere() { areas = [Self.anywhere] }

  /// Adds an area drawn on the map. A drawn area replaces "anywhere".
  mutating func add(area: SearchArea) {
    areas.removeAll { $0.id == Self.anywhere.id }
    guard areas.count < Self.areaLimit else { return }
    areas.append(area)
  }

  mutating func remove(areaID: String) { areas.removeAll { $0.id == areaID } }

  // MARK: Must-haves

  mutating func toggle(mustHave: String) {
    if let index = mustHaves.firstIndex(of: mustHave) {
      mustHaves.remove(at: index)
    } else if mustHaves.count < 20 {
      mustHaves.append(mustHave)
    }
  }

  /// The same words a place is listed with, so a must-have can match one, followed by any this
  /// search already has that are not among them.
  var mustHaveChoices: [String] {
    ListingForm.commonAmenities + mustHaves.filter { !ListingForm.commonAmenities.contains($0) }
  }

  // MARK: Moving on

  /// What stops this step from being finished, in words for the person, or nothing.
  func problem(for step: SearchStep, today: Date = Date()) -> String? {
    switch step {
    case .dates:
      if isoDay(end) <= isoDay(start) { return "Move out has to be after move in." }
      if isoDay(end) <= isoDay(today) { return "Move out has to be in the future." }
      return nil
    case .place:
      return areas.isEmpty ? "Say where: anywhere in Syracuse, or draw an area on the map." : nil
    case .about:
      return introduction.count > Self.introductionLimit
        ? "Keep it to \(Self.introductionLimit) characters." : nil
    }
  }

  // MARK: Saving

  /// What `POST /api/my-search` takes. A search that is on can be found and matched.
  func payload(active: Bool) -> [String: Any] {
    var body: [String: Any] = [
      "startDate": isoDay(start), "endDate": isoDay(end), "maxBudget": Double(budget),
      "roomType": kind, "requiredAmenities": mustHaves, "preferredAmenities": preferred,
      "areas": areas.map { area in
        [
          "id": area.id, "label": area.label,
          "points": area.points.map { ["lat": $0.lat, "lng": $0.lng] },
        ] as [String: Any]
      },
      "introduction": introduction.trimmingCharacters(in: .whitespacesAndNewlines),
      "status": active ? "active" : "paused",
    ]
    if let minBudget, minBudget <= Double(budget) { body["minBudget"] = minBudget }
    if let minBedrooms, kind == "Entire place" { body["minBedrooms"] = minBedrooms }
    return body
  }

  // MARK: How many fit

  /// How many of these places fit the answers so far. Until somewhere is chosen, everywhere
  /// counts. The server decides the real matches; this is the same rule, run on the phone.
  func fits(_ listings: [Listing], viewerID: String?, today: String = isoDay(Date())) -> Int {
    let search = HousingSearch(
      id: "", ownerId: viewerID ?? "", ownerName: "", ownerIdentity: "", status: "active",
      startDate: isoDay(start), endDate: isoDay(end),
      minBudget: minBudget.flatMap { $0 <= Double(budget) ? $0 : nil },
      maxBudget: Double(budget), minBedrooms: kind == "Entire place" ? minBedrooms : nil,
      roomType: kind, requiredAmenities: mustHaves, preferredAmenities: preferred,
      areas: areas.isEmpty ? [Self.anywhere] : areas, introduction: "", createdAt: nil)
    return listings.filter { housingFits($0, search, today: today) }.count
  }
}

/// The words the search steps and the "What you're looking for" page use.
enum SearchText {
  static func fits(_ count: Int) -> String {
    switch count {
    case 0: return "No places fit yet"
    case 1: return "1 place fits so far"
    default: return "\(count) places fit so far"
    }
  }

  static func fitsNow(_ count: Int) -> String {
    switch count {
    case 0: return "No places fit right now"
    case 1: return "1 place fits right now"
    default: return "\(count) places fit right now"
    }
  }

  static func budget(_ dollarsAMonth: Int) -> String { dollars(Double(dollarsAMonth)) }

  struct Row: Equatable, Identifiable {
    let title: String
    let value: String
    /// The step that changes it.
    let step: SearchStep
    var id: String { title }
  }

  /// A saved search, one line per thing it says.
  static func rows(_ search: HousingSearch) -> [Row] {
    let money: String
    if let low = search.minBudget {
      money = "\(dollars(low)) to \(dollars(search.maxBudget)) a month"
    } else {
      money = "Up to \(dollars(search.maxBudget)) a month"
    }
    var kind: String
    switch search.roomType {
    case "Any": kind = "Either a room or an entire place"
    default: kind = search.roomType
    }
    if search.roomType == "Entire place", let beds = search.minBedrooms {
      let number = beds.formatted(.number.precision(.fractionLength(0...1)))
      kind += " · \(number) or more bedroom\(beds == 1 ? "" : "s")"
    }
    let hello = search.introduction.trimmingCharacters(in: .whitespacesAndNewlines)
    return [
      .init(
        title: "Dates", value: QuadFormat.dateRange(search.startDate, search.endDate),
        step: .dates),
      .init(title: "Budget", value: money, step: .dates),
      .init(title: "Kind of place", value: kind, step: .place),
      .init(title: "Where", value: search.areas.map(\.label).joined(separator: ", "), step: .place),
      .init(
        title: "Must-haves",
        value: search.requiredAmenities.isEmpty
          ? "None" : search.requiredAmenities.joined(separator: ", "), step: .place),
      .init(title: "About you", value: hello.isEmpty ? "Nothing yet" : hello, step: .about),
    ]
  }
}
