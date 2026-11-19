import Foundation

/// One thing in a conversation: something said, offered, shared or done.
enum ChatItem: Identifiable, Equatable {
  /// A heading where a new day starts: "Today", "Mon, Nov 9".
  case day(String)
  case message(id: String, body: String, mine: Bool)
  case offer(id: String)
  case document(id: String, name: String, mine: Bool)
  /// Something that happened and has no card of its own, such as a confirmed move-in.
  case note(id: String, text: String)
  case booking(id: String)

  var id: String {
    switch self {
    case .day(let label): return "day-" + label
    case .message(let id, _, _): return "message-" + id
    case .offer(let id): return "offer-" + id
    case .document(let id, _, _): return "document-" + id
    case .note(let id, _): return "note-" + id
    case .booking(let id): return "booking-" + id
    }
  }
}

/// Puts a conversation's messages, offers, shared documents, events and reservations into the
/// one order they happened in. The server sends them as separate lists.
enum ChatTimeline {
  /// Events an offer or document card already shows.
  private static let shownByACard: Set<String> = [
    "offer", "request", "counteroffer", "document", "accepted", "declined", "withdrawn",
  ]

  static func items(
    _ detail: ConversationDetail, viewerID: String?, now: Date = Date(),
    timeZone: TimeZone = marketplaceTimeZone
  ) -> [ChatItem] {
    var dated: [(Date, Int, ChatItem)] = []
    var undated: [ChatItem] = []
    func add(_ item: ChatItem, at moment: String?) {
      if let date = ChatText.date(moment) {
        dated.append((date, dated.count, item))
      } else {
        undated.append(item)
      }
    }
    for m in detail.messages {
      add(.message(id: m.id, body: m.body, mine: m.senderId == viewerID), at: m.createdAt)
    }
    for a in detail.attachments {
      add(.document(id: a.id, name: a.name, mine: a.senderId == viewerID), at: a.createdAt)
    }
    for o in detail.offers { add(.offer(id: o.id), at: o.createdAt) }
    for e in detail.events where !shownByACard.contains(e.kind) {
      add(.note(id: e.id, text: e.body), at: e.createdAt)
    }
    for b in detail.bookings { add(.booking(id: b.id), at: b.createdAt) }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    var items: [ChatItem] = []
    var lastDay: Date?
    // Things that share a moment keep the order they were added in.
    for (date, _, item) in dated.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) {
      let day = calendar.startOfDay(for: date)
      if day != lastDay {
        items.append(.day(ChatText.day(date, now: now, timeZone: timeZone)))
        lastDay = day
      }
      items.append(item)
    }
    // An older server gives offers, documents and reservations no time. They go last, offers
    // first, as the old screen listed them.
    func rank(_ item: ChatItem) -> Int {
      switch item {
      case .offer: return 0
      case .document: return 1
      case .booking: return 2
      default: return 3
      }
    }
    return items
      + undated.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
      .map(\.element)
  }
}

/// The words a conversation and the Inbox use.
enum ChatText {
  // MARK: Dates

  /// When a thread last changed, as short as it can be said: "9:05 AM", "Yesterday", "Fri",
  /// "Oct 2", "Dec 30, 2025". Empty when the server gave no usable time.
  static func stamp(
    _ moment: String?, now: Date = Date(), timeZone: TimeZone = marketplaceTimeZone
  ) -> String {
    guard let date = date(moment) else { return "" }
    switch daysBefore(date, now: now, timeZone: timeZone) {
    case 0: return format("h:mm a", date, timeZone)
    case 1: return "Yesterday"
    case 2...6: return format("EEE", date, timeZone)
    default: return sameYear(date, now, timeZone) ? format("MMM d", date, timeZone)
        : format("MMM d, yyyy", date, timeZone)
    }
  }

  /// The heading over a day in a thread: "Today", "Yesterday", "Mon, Nov 9", "Nov 9, 2025".
  static func day(_ date: Date, now: Date = Date(), timeZone: TimeZone = marketplaceTimeZone)
    -> String
  {
    switch daysBefore(date, now: now, timeZone: timeZone) {
    case 0: return "Today"
    case 1: return "Yesterday"
    default: return sameYear(date, now, timeZone) ? format("EEE, MMM d", date, timeZone)
        : format("MMM d, yyyy", date, timeZone)
    }
  }

  /// A moment as the server writes one, with or without fractions of a second.
  static func date(_ moment: String?) -> Date? {
    guard let moment, !moment.isEmpty else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = f.date(from: moment) { return date }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: moment)
  }

  private static func daysBefore(_ date: Date, now: Date, timeZone: TimeZone) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
    ).day ?? 0
  }

  private static func sameYear(_ a: Date, _ b: Date, _ timeZone: TimeZone) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.component(.year, from: a) == calendar.component(.year, from: b)
  }

  private static func format(_ pattern: String, _ date: Date, _ timeZone: TimeZone) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = timeZone
    f.dateFormat = pattern
    return f.string(from: date)
  }

  // MARK: The Inbox row

  static func preview(_ lastMessage: String?) -> String {
    let text = (lastMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "No messages yet" : text
  }

  struct Identity: Equatable {
    let text: String
    let checked: Bool
  }

  /// What to say about the other person's ID, or nothing when the server did not say.
  static func identity(_ identity: String?) -> Identity? {
    guard let identity else { return nil }
    return identity == "verified"
      ? .init(text: "ID checked", checked: true) : .init(text: "ID not checked", checked: false)
  }

  // MARK: An offer

  enum Tone: Equatable { case waiting, good, over }
  enum OfferAction: Equatable { case withdraw, accept, counter, decline }

  struct OfferCard: Equatable {
    let heading: String
    let status: String
    let tone: Tone
    /// "$900"; the card adds "/ month".
    let amount: String
    /// "Jan 5 – May 15 · entire place".
    let terms: String
    let actions: [OfferAction]
  }

  static func offer(_ offer: Offer, viewerID: String?, peerName: String, roomType: String)
    -> OfferCard
  {
    let mine = offer.proposedBy == viewerID
    let first = QuadFormat.firstName(peerName)
    let whose = mine ? "Your" : first + "'s"
    let what: String
    if offer.parentOfferId != nil {
      what = "counteroffer"
    } else if offer.kind == "request" {
      what = "request at the asking price"
    } else {
      what = "offer"
    }
    let status: String
    let tone: Tone
    var actions: [OfferAction] = []
    switch offer.status {
    case "pending":
      status = mine ? "Waiting for \(first)" : "Waiting for you"
      tone = .waiting
      // The server lets only the proposer withdraw and only the other person answer.
      actions = mine ? [.withdraw] : [.accept, .counter, .decline]
    case "accepted":
      status = "Accepted"
      tone = .good
    default:
      status = plain(offer.status)
      tone = .over
    }
    return OfferCard(
      heading: "\(whose) \(what)", status: status, tone: tone, amount: dollars(offer.amount),
      terms: QuadFormat.dateRange(offer.startDate, offer.endDate) + " · " + roomType.lowercased(),
      actions: actions)
  }

  /// A status as the server stores it, in words: "demo_paid" becomes "Demo paid".
  static func plain(_ status: String) -> String {
    let words = status.replacingOccurrences(of: "_", with: " ")
    return words.prefix(1).uppercased() + words.dropFirst()
  }

  // MARK: Quick replies

  struct QuickReply: Equatable, Identifiable {
    let label: String
    /// What the reply puts in the message box, or nothing when it opens the offer form.
    let text: String?
    var id: String { label }
  }

  /// The shortcuts over the message box. Someone asking about a place asks to see it; its owner
  /// offers to show it.
  static func quickReplies(viewerOwnsPlace: Bool) -> [QuickReply] {
    let offer = QuickReply(label: "Make an offer", text: nil)
    if viewerOwnsPlace {
      return [
        offer,
        .init(
          label: "Offer a visit",
          text: "Would you like to come and see the place? Tell me what days work for you."),
      ]
    }
    return [
      offer,
      .init(
        label: "Ask to visit", text: "Could I come and see the place? What days work for you?"),
      .init(label: "Move-in day", text: "What day could I move in?"),
    ]
  }
}
