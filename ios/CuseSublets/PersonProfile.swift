import Foundation

/// The words on a person's profile that are worked out from data.
enum PersonText {
  struct Rating: Equatable {
    /// "4.7"
    let value: String
    /// "from 3 reviews"
    let caption: String
  }

  /// "Member since September 2026". Nil when the server has no date for the account.
  static func memberSince(_ joined: String?) -> String? {
    month(joined).map { "Member since \($0)" }
  }

  /// The average of the star ratings, to one decimal. Nil when there are no reviews.
  static func rating(_ ratings: [Int]) -> Rating? {
    guard !ratings.isEmpty else { return nil }
    let average = Double(ratings.reduce(0, +)) / Double(ratings.count)
    return Rating(
      value: String(format: "%.1f", average),
      caption: "from \(ratings.count) review\(ratings.count == 1 ? "" : "s")")
  }

  /// What someone is doing here now, as chips.
  static func roles(places: Int, looking: Bool) -> [String] {
    var chips: [String] = []
    if places == 1 { chips.append("Subleasing a place") }
    if places > 1 { chips.append("Subleasing \(places) places") }
    if looking { chips.append("Looking for a place") }
    return chips
  }

  static func placesHeading(name: String, count: Int) -> String {
    "\(QuadFormat.firstName(name))'s place\(count == 1 ? "" : "s")"
  }

  /// "Subtenant · stay ended May 2026". A server from before the redesign sends neither part.
  static func reviewer(role: String?, stayEnded: String?) -> String {
    let side: String?
    switch role {
    case "subtenant": side = "Subtenant"
    case "subleaser": side = "Subleaser"
    default: side = nil
    }
    let ended = month(stayEnded)
    switch (side, ended) {
    case (let side?, let ended?): return "\(side) · stay ended \(ended)"
    case (let side?, nil): return side
    case (nil, let ended?): return "Stay ended \(ended)"
    case (nil, nil): return ""
    }
  }

  /// "Private room · up to $1,000 / month".
  static func looking(_ search: HousingSearch) -> String {
    let kind = search.roomType == "Any" ? "Any kind of place" : search.roomType
    return "\(kind) · up to \(dollars(search.maxBudget)) / month"
  }

  /// "September 2026" from "2026-09" or from a longer date that starts that way.
  private static func month(_ value: String?) -> String? {
    guard let value, value.count >= 7 else { return nil }
    let parse = DateFormatter()
    parse.locale = Locale(identifier: "en_US_POSIX")
    parse.timeZone = TimeZone(identifier: "UTC")
    parse.dateFormat = "yyyy-MM"
    parse.isLenient = false
    guard let date = parse.date(from: String(value.prefix(7))) else { return nil }
    parse.dateFormat = "LLLL yyyy"
    return parse.string(from: date)
  }
}

/// One way to start a conversation with a person. Every conversation is about a place.
struct PersonMessageChoice: Equatable, Identifiable {
  let listingID: String
  /// Set when the viewer is offering a place of their own to this person's search.
  let searchID: String?
  let label: String
  var id: String { listingID + "/" + (searchID ?? "") }
}

enum PersonMessage {
  /// What the viewer can message this person about: any place the person has up, then any
  /// place of the viewer's own that fits what the person is looking for. The server checks
  /// again when the conversation is opened.
  static func choices(
    viewerID: String?, personID: String, theirPlaces: [Listing], theirSearch: HousingSearch?,
    myPlaces: [Listing], today: String = isoDay(Date())
  ) -> [PersonMessageChoice] {
    guard viewerID != personID else { return [] }
    var choices = theirPlaces.map {
      PersonMessageChoice(listingID: $0.id, searchID: nil, label: "About \($0.title)")
    }
    if let theirSearch {
      choices += myPlaces.filter { housingFits($0, theirSearch, today: today) }.map {
        PersonMessageChoice(
          listingID: $0.id, searchID: theirSearch.id, label: "Offer \($0.title)")
      }
    }
    return choices
  }

  /// Said in place of the Message button when there is nothing to message about.
  static func unavailable(name: String, looking: Bool) -> String {
    let first = QuadFormat.firstName(name)
    return "Conversations here are about a place. "
      + (looking
        ? "To message \(first), list a place that fits what they're looking for."
        : "\(first) has no place listed and no search open right now.")
  }
}
