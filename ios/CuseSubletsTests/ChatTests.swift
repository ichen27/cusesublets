import XCTest

@testable import CuseSublets

final class ChatTests: XCTestCase {
  private let newYork = TimeZone(identifier: "America/New_York")!
  /// Tuesday 17 November 2026, 3:00 pm in Syracuse.
  private var now: Date { moment("2026-11-17T20:00:00.000Z") }

  // MARK: The Inbox row

  func testAThreadFromTodayShowsItsTime() {
    XCTAssertEqual(stamp("2026-11-17T14:05:00.000Z"), "9:05 AM")
  }

  func testAThreadFromYesterdaySaysSo() {
    XCTAssertEqual(stamp("2026-11-16T23:00:00.000Z"), "Yesterday")
  }

  func testAThreadFromThisWeekShowsItsWeekday() {
    XCTAssertEqual(stamp("2026-11-13T15:00:00.000Z"), "Fri")
  }

  func testAnOlderThreadShowsItsDateAndTheYearOnlyWhenItDiffers() {
    XCTAssertEqual(stamp("2026-10-02T15:00:00.000Z"), "Oct 2")
    XCTAssertEqual(stamp("2025-12-30T15:00:00.000Z"), "Dec 30, 2025")
  }

  func testTheDayIsTheOneInSyracuseNotInLondon() {
    // 2 am on the 17th in London is still the evening of the 16th in Syracuse.
    XCTAssertEqual(stamp("2026-11-17T02:00:00.000Z"), "Yesterday")
  }

  func testAThreadWithNoDateShowsNone() {
    XCTAssertEqual(stamp(nil), "")
    XCTAssertEqual(stamp("soon"), "")
  }

  func testAnEmptyThreadSaysNothingHasBeenSaid() {
    XCTAssertEqual(ChatText.preview(nil), "No messages yet")
    XCTAssertEqual(ChatText.preview("  "), "No messages yet")
    XCTAssertEqual(ChatText.preview("Is it still open?"), "Is it still open?")
  }

  func testTheIDLineSaysWhatStaffHaveChecked() {
    XCTAssertEqual(ChatText.identity("verified"), .init(text: "ID checked", checked: true))
    XCTAssertEqual(ChatText.identity("pending"), .init(text: "ID not checked", checked: false))
    // An older server does not say, so nothing is claimed either way.
    XCTAssertNil(ChatText.identity(nil))
  }

  // MARK: An offer

  func testMyWaitingOfferCanOnlyBeWithdrawn() {
    let card = ChatText.offer(
      offer(by: "me"), viewerID: "me", peerName: "Jamie Chen", roomType: "Entire place")
    XCTAssertEqual(card.heading, "Your offer")
    XCTAssertEqual(card.status, "Waiting for Jamie")
    XCTAssertEqual(card.tone, .waiting)
    XCTAssertEqual(card.amount, "$900")
    XCTAssertEqual(card.terms, "Jan 5 – May 15 · entire place")
    XCTAssertEqual(card.actions, [.withdraw])
  }

  func testTheirWaitingOfferIsMineToAnswer() {
    let card = ChatText.offer(
      offer(by: "jamie"), viewerID: "me", peerName: "Jamie Chen", roomType: "Private room")
    XCTAssertEqual(card.heading, "Jamie's offer")
    XCTAssertEqual(card.status, "Waiting for you")
    XCTAssertEqual(card.actions, [.accept, .counter, .decline])
  }

  func testAnAnsweredOfferSaysHowAndOffersNothingMore() {
    for (status, words, tone) in [
      ("accepted", "Accepted", ChatText.Tone.good), ("declined", "Declined", .over),
      ("withdrawn", "Withdrawn", .over),
    ] {
      let card = ChatText.offer(
        offer(by: "jamie", status: status), viewerID: "me", peerName: "Jamie Chen",
        roomType: "Private room")
      XCTAssertEqual(card.status, words)
      XCTAssertEqual(card.tone, tone)
      XCTAssertEqual(card.actions, [])
    }
  }

  func testACounterofferAndAnAskingPriceRequestAreNamedForWhatTheyAre() {
    XCTAssertEqual(
      ChatText.offer(
        offer(by: "me", parent: "first"), viewerID: "me", peerName: "Jamie Chen",
        roomType: "Private room"
      ).heading, "Your counteroffer")
    XCTAssertEqual(
      ChatText.offer(
        offer(by: "jamie", kind: "request"), viewerID: "me", peerName: "Jamie Chen",
        roomType: "Private room"
      ).heading, "Jamie's request at the asking price")
  }

  // MARK: Quick replies

  func testSomeoneAskingAboutAPlaceCanOfferAskToVisitOrAskWhenToMoveIn() {
    let replies = ChatText.quickReplies(viewerOwnsPlace: false)
    XCTAssertEqual(replies.map(\.label), ["Make an offer", "Ask to visit", "Move-in day"])
    XCTAssertNil(replies[0].text, "Making an offer opens the offer form instead of writing text")
    XCTAssertEqual(replies[1].text, "Could I come and see the place? What days work for you?")
  }

  func testThePlacesOwnerOffersAVisitInsteadOfAskingForOne() {
    XCTAssertEqual(
      ChatText.quickReplies(viewerOwnsPlace: true).map(\.label),
      ["Make an offer", "Offer a visit"])
  }

  // MARK: The thread, in order

  func testEverythingInAThreadIsShownInTheOrderItHappened() throws {
    let detail = try thread(
      messages: [
        message("m1", from: "jamie", "Hi Alex!", at: "2026-11-16T15:00:00.000Z"),
        message("m2", from: "me", "Is the garage included?", at: "2026-11-17T14:00:00.000Z"),
      ],
      offers: [#"{"id":"o1","proposedBy":"me","amount":900,"startDate":"2027-01-05","endDate":"2027-05-15","status":"pending","kind":"offer","createdAt":"2026-11-17T14:30:00.000Z"}"#],
      attachments: [#"{"id":"a1","name":"lease.pdf","senderId":"jamie","createdAt":"2026-11-17T14:10:00.000Z"}"#],
      events: [
        event("e1", kind: "offer", "Offer sent", at: "2026-11-17T14:30:00.000Z"),
        event("e2", kind: "document", "Shared lease.pdf", at: "2026-11-17T14:10:00.000Z"),
        event("e3", kind: "confirm-move-in", "Renter confirmed move-in", at: "2026-11-17T15:00:00.000Z"),
      ])
    XCTAssertEqual(
      ChatTimeline.items(detail, viewerID: "me", now: now, timeZone: newYork),
      [
        .day("Yesterday"),
        .message(id: "m1", body: "Hi Alex!", mine: false),
        .day("Today"),
        .message(id: "m2", body: "Is the garage included?", mine: true),
        .document(id: "a1", name: "lease.pdf", mine: false),
        .offer(id: "o1"),
        // The offer and the document already have cards, so their events are not repeated.
        .note(id: "e3", text: "Renter confirmed move-in"),
      ])
  }

  func testAnOlderDayIsNamedByItsDate() throws {
    let detail = try thread(messages: [
      message("m1", from: "jamie", "Hello", at: "2026-11-09T15:00:00.000Z"),
      message("m2", from: "jamie", "Still there?", at: "2025-11-09T15:00:00.000Z"),
    ])
    XCTAssertEqual(
      ChatTimeline.items(detail, viewerID: "me", now: now, timeZone: newYork).filter {
        if case .day = $0 { return true } else { return false }
      }, [.day("Nov 9, 2025"), .day("Mon, Nov 9")])
  }

  func testWhatAnOlderServerSendsWithoutATimeGoesAfterEverythingDated() throws {
    let detail = try thread(
      messages: [message("m1", from: "jamie", "Hello", at: "2026-11-17T14:00:00.000Z")],
      offers: [#"{"id":"o1","proposedBy":"me","amount":900,"startDate":"2027-01-05","endDate":"2027-05-15","status":"pending","kind":"offer"}"#],
      attachments: [#"{"id":"a1","name":"lease.pdf"}"#],
      bookings: [#"{"id":"b1","amount":900,"startDate":"2027-01-05","endDate":"2027-05-15","status":"reserved","paymentStatus":"unpaid","disputeStatus":"none","buyerId":"me"}"#])
    XCTAssertEqual(
      ChatTimeline.items(detail, viewerID: "me", now: now, timeZone: newYork),
      [
        .day("Today"), .message(id: "m1", body: "Hello", mine: false), .offer(id: "o1"),
        .document(id: "a1", name: "lease.pdf", mine: false), .booking(id: "b1"),
      ])
  }

  func testAThreadSaysWhetherTheOtherPersonsIDIsChecked() throws {
    XCTAssertNil(try thread().peer.identity)
    XCTAssertEqual(try thread(peerIdentity: "verified").peer.identity, "verified")
  }

  func testAReservationIsDescribedInPlainWords() {
    XCTAssertEqual(ChatText.plain("demo_paid"), "Demo paid")
    XCTAssertEqual(ChatText.plain("pending"), "Pending")
    XCTAssertEqual(ChatText.plain(""), "")
  }

  // MARK: Fixtures

  private func stamp(_ value: String?) -> String {
    ChatText.stamp(value, now: now, timeZone: newYork)
  }

  private func moment(_ value: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: value)!
  }

  private func offer(
    by proposer: String, status: String = "pending", kind: String = "offer", parent: String? = nil
  ) -> Offer {
    Offer(
      id: "o1", proposedBy: proposer, amount: 900, startDate: "2027-01-05",
      endDate: "2027-05-15", status: status, kind: kind, parentOfferId: parent,
      createdAt: "2026-11-17T14:30:00.000Z")
  }

  private func message(_ id: String, from sender: String, _ body: String, at: String) -> String {
    #"{"id":"\#(id)","senderId":"\#(sender)","body":"\#(body)","createdAt":"\#(at)"}"#
  }

  private func event(_ id: String, kind: String, _ body: String, at: String) -> String {
    #"{"id":"\#(id)","kind":"\#(kind)","body":"\#(body)","createdAt":"\#(at)"}"#
  }

  private func thread(
    peerIdentity: String? = nil, messages: [String] = [], offers: [String] = [],
    attachments: [String] = [], events: [String] = [], bookings: [String] = []
  ) throws -> ConversationDetail {
    let identity = peerIdentity.map { #","identity":"\#($0)""# } ?? ""
    let json = #"""
      {"conversation":{"id":"c1","listingId":"l1","listingTitle":"Sunny room","listingImage":"","peerName":"Jamie Chen","lastMessage":""},
       "peer":{"id":"jamie","name":"Jamie Chen"\#(identity)},
       "listing":{"id":"l1","ownerId":"jamie","title":"Sunny room","neighborhood":"Westcott","address":"","lat":43.04,"lng":-76.13,"price":950,"beds":1,"baths":1,"roomType":"Private room","startDate":"2027-01-05","endDate":"2027-05-15","description":"","amenities":[],"images":[],"status":"approved","leaseStatus":"pending","permissionStatus":"pending","hostName":"Jamie Chen","hostIdentity":"pending","sample":false},
       "messages":[\#(messages.joined(separator: ","))],
       "offers":[\#(offers.joined(separator: ","))],
       "bookings":[\#(bookings.joined(separator: ","))],
       "attachments":[\#(attachments.joined(separator: ","))],
       "events":[\#(events.joined(separator: ","))]}
      """#
    return try JSONDecoder().decode(ConversationDetail.self, from: Data(json.utf8))
  }
}
