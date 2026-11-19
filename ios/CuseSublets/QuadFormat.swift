import Foundation

/// Small text rules shared by the redesigned screens.
enum QuadFormat {
  /// "Jan 5 – May 15", or with both years when the stay crosses a new year. Dates are
  /// `yyyy-MM-dd` days in the marketplace's time zone; anything else is shown as it came.
  static func dateRange(_ start: String, _ end: String) -> String {
    guard let from = day(start), let to = day(end) else { return "\(start) – \(end)" }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = marketplaceTimeZone
    let sameYear = calendar.component(.year, from: from) == calendar.component(.year, from: to)
    let format = formatter(sameYear ? "MMM d" : "MMM d, yyyy")
    return "\(format.string(from: from)) – \(format.string(from: to))"
  }

  /// Up to two capital letters for an avatar without a photo.
  static func initials(_ name: String) -> String {
    let words = name.split(whereSeparator: \.isWhitespace)
    guard let first = words.first?.first else { return "?" }
    let last = words.count > 1 ? words.last?.first : nil
    return String([first, last].compactMap { $0 }).uppercased()
  }

  /// Which of `count` avatar colours a person gets. The same person always gets the same one.
  static func tintIndex(for id: String, count: Int) -> Int {
    guard count > 0 else { return 0 }
    // Swift's own hashing changes between launches, so this uses a fixed one (djb2).
    let hash = id.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
    return Int(hash % UInt64(count))
  }

  static func subleasing(in neighborhood: String) -> String {
    let place = neighborhood.trimmingCharacters(in: .whitespaces)
    return place.isEmpty ? "Subleasing a place" : "Subleasing in \(place)"
  }

  /// One line of the "what has been checked" card.
  struct Check: Equatable {
    let text: String
    let done: Bool
  }
  /// What staff have and have not checked for a place, in the order shown.
  static func checks(hostName: String, identity: String, lease: String) -> [Check] {
    let name = firstName(hostName)
    return [
      identity == "verified"
        ? Check(text: "\(name)'s ID matches their profile", done: true)
        : Check(text: "\(name)'s ID not checked yet", done: false),
      lease == "verified"
        ? Check(text: "Lease for this place reviewed by staff", done: true)
        : Check(text: "Lease not checked yet", done: false),
    ]
  }

  static func firstName(_ name: String) -> String {
    name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "this member"
  }

  /// "Entire place · 1 bed · 1.5 baths · Jan 5 – May 15".
  static func stay(roomType: String, beds: Double, baths: Double, start: String, end: String)
    -> String
  {
    func count(_ value: Double, _ noun: String) -> String {
      let number = value.formatted(.number.precision(.fractionLength(0...1)))
      return "\(number) \(noun)\(value == 1 ? "" : "s")"
    }
    return [roomType, count(beds, "bed"), count(baths, "bath"), dateRange(start, end)]
      .joined(separator: " · ")
  }

  private static func formatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = marketplaceTimeZone
    f.dateFormat = format
    return f
  }

  private static func day(_ value: String) -> Date? {
    let f = formatter("yyyy-MM-dd")
    f.isLenient = false
    return f.date(from: value)
  }
}

/// The four places the tab bar leads to. Raw values match `AppState.tab`.
enum QuadTab: Int, CaseIterable {
  case home, matches, inbox, you

  var title: String {
    switch self {
    case .home: return "Home"
    case .matches: return "Matches"
    case .inbox: return "Inbox"
    case .you: return "You"
    }
  }

  var symbol: String {
    switch self {
    case .home: return "house"
    case .matches: return "person.2"
    case .inbox: return "bubble.left"
    case .you: return "person"
    }
  }

  /// Stable name for interface tests.
  var identifier: String { "tab-" + title.lowercased() }
}
