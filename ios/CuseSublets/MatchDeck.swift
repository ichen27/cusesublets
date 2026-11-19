import Foundation

/// The matches for one of a person's plans, shown one at a time, best first. A match is "seen"
/// once the person has passed on it, saved it or messaged about it.
struct MatchDeck: Equatable {
  private(set) var ids: [String]
  /// In the order they were seen, so the last one can be brought back.
  private(set) var seen: [String]

  /// `seen` may come from an earlier day; anything in it that no longer fits is forgotten.
  init(ids: [String], seen: [String] = []) {
    self.ids = ids
    let fitting = Set(ids)
    self.seen = seen.filter(fitting.contains)
  }

  var total: Int { ids.count }
  var current: String? {
    let done = Set(seen)
    return ids.first { !done.contains($0) }
  }
  var canGoBack: Bool { !seen.isEmpty }
  /// There were matches and every one has been seen.
  var isFinished: Bool { total > 0 && current == nil }

  mutating func moveOn() {
    if let current { seen.append(current) }
  }
  mutating func goBack() {
    if !seen.isEmpty { seen.removeLast() }
  }
  mutating func startAgain() { seen = [] }
}

/// Remembers on this iPhone which matches a person has seen for each of their plans, so the
/// deck picks up where it was left. The server does not record this.
struct MatchSeenStore {
  var defaults = UserDefaults.standard

  func seen(user: String, plan: String) -> [String] {
    defaults.stringArray(forKey: key(user, plan)) ?? []
  }
  func save(_ seen: [String], user: String, plan: String) {
    if seen.isEmpty {
      defaults.removeObject(forKey: key(user, plan))
    } else {
      defaults.set(seen, forKey: key(user, plan))
    }
  }
  /// Removes everything remembered for one person, for when their account is deleted.
  func forget(user: String) {
    let prefix = "matches.seen.\(user)."
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
      defaults.removeObject(forKey: key)
    }
  }
  private func key(_ user: String, _ plan: String) -> String { "matches.seen.\(user).\(plan)" }
}

/// What dragging the card sideways means once the finger lifts.
enum MatchSwipe: Equatable {
  case pass, save

  /// A drag of at least 30% of the card's width counts: left passes, right saves.
  static func choice(translation: Double, width: Double) -> MatchSwipe? {
    guard width > 0, abs(translation) >= width * 0.3 else { return nil }
    return translation < 0 ? .pass : .save
  }
}

/// The words on the Matches screen that are worked out from data.
enum MatchText {
  /// Who is reading the reasons.
  enum Viewer {
    /// The person looking for a place, reading about a place.
    case seeker
    /// The person subleasing, reading about someone who is looking.
    case host(seeker: String)
  }

  /// "3 of 8 that fit". Empty when no match is showing: there are none, or all were seen.
  static func position(_ deck: MatchDeck) -> String {
    guard deck.current != nil else { return "" }
    let place = deck.seen.count + 1
    return "\(place) of \(deck.total) that \(deck.total == 1 ? "fits" : "fit")"
  }

  /// Why a place fits a search, in the order the search was filled in. The server decides
  /// whether the two match at all; this only puts the numbers into the reasons.
  static func reasons(listing: Listing, search: HousingSearch, for viewer: Viewer) -> [String] {
    let budget = dollars(search.maxBudget)
    let dates = QuadFormat.dateRange(search.startDate, search.endDate)
    let area = search.areas.first { $0.contains(.init(lat: listing.lat, lng: listing.lng)) }?.label
    let kind = search.roomType == "Any" ? nil : roomKind(search.roomType)
    let bedrooms = search.roomType == "Entire place" ? search.minBedrooms.map { Int($0) } : nil
    let offered = Set(listing.amenities.map(normal))
    let needed = search.requiredAmenities
    let liked = search.preferredAmenities.filter { offered.contains(normal($0)) }

    var lines: [String] = []
    switch viewer {
    case .seeker:
      lines.append("Inside your \(budget) budget")
      lines.append("Covers \(dates)")
      if let area { lines.append("In your \(area) area") }
      if let kind { lines.append("\(kind.prefix(1).uppercased())\(kind.dropFirst()), as you asked") }
      if let bedrooms {
        lines.append("At least \(bedrooms) bedroom\(bedrooms == 1 ? "" : "s"), as you asked")
      }
      if !needed.isEmpty { lines.append("Has what you need: \(list(needed))") }
      if !liked.isEmpty { lines.append("Also has \(list(liked)), which you'd like") }
    case .host(let seeker):
      let name = QuadFormat.firstName(seeker)
      lines.append("Your rent is inside \(name)'s \(budget) budget")
      lines.append("Your dates cover \(dates)")
      if let area { lines.append("Your place is in \(name)'s \(area) area") }
      if let kind { lines.append("\(name) wants \(kind)") }
      if let bedrooms {
        lines.append("\(name) needs at least \(bedrooms) bedroom\(bedrooms == 1 ? "" : "s")")
      }
      if !needed.isEmpty { lines.append("Your place has what \(name) needs: \(list(needed))") }
      if !liked.isEmpty { lines.append("It also has \(list(liked)), which \(name) would like") }
    }
    return lines
  }

  /// One line under a person's name saying what staff have and have not checked.
  static func checks(identity: String, lease: String) -> String {
    (identity == "verified" ? "ID checked" : "ID not checked") + " · "
      + (lease == "verified" ? "lease checked by staff" : "lease not checked")
  }

  /// "Laundry", "Laundry and Gym", "Laundry, Gym and Parking".
  static func list(_ items: [String]) -> String {
    guard let last = items.last else { return "" }
    return items.count == 1 ? last : items.dropLast().joined(separator: ", ") + " and " + last
  }

  /// The chip that says whose matches are showing.
  static func planLabel(search: Bool, title: String) -> String {
    search ? "For your search" : "For \(title)"
  }

  private static func roomKind(_ roomType: String) -> String {
    roomType == "Entire place" ? "an entire place" : "a private room"
  }

  private static func normal(_ amenity: String) -> String {
    amenity.trimmingCharacters(in: .whitespaces).lowercased()
  }
}
