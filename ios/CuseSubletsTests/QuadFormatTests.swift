import XCTest

@testable import CuseSublets

final class QuadFormatTests: XCTestCase {
  func testDateRangeInOneYearLeavesTheYearOut() {
    XCTAssertEqual(QuadFormat.dateRange("2027-01-05", "2027-05-15"), "Jan 5 – May 15")
  }

  func testDateRangeAcrossYearsShowsBothYears() {
    XCTAssertEqual(
      QuadFormat.dateRange("2026-12-16", "2027-05-15"), "Dec 16, 2026 – May 15, 2027")
  }

  func testDateRangeFallsBackToTheRawTextWhenADateIsNotADay() {
    XCTAssertEqual(QuadFormat.dateRange("soon", "2027-05-15"), "soon – 2027-05-15")
  }

  func testInitialsUseTheFirstAndLastName() {
    XCTAssertEqual(QuadFormat.initials("Jamie Chen"), "JC")
    XCTAssertEqual(QuadFormat.initials("mary ann  lee"), "ML")
  }

  func testInitialsOfOneNameAreOneLetter() {
    XCTAssertEqual(QuadFormat.initials("alex"), "A")
  }

  func testInitialsOfAnEmptyNameAreAQuestionMark() {
    XCTAssertEqual(QuadFormat.initials("   "), "?")
  }

  func testTintIsStableForAPersonAndWithinThePalette() {
    let first = QuadFormat.tintIndex(for: "demo-host", count: 3)
    XCTAssertEqual(first, QuadFormat.tintIndex(for: "demo-host", count: 3))
    for id in ["a", "b", "demo-renter", "8f1c2a", ""] {
      XCTAssertTrue((0..<3).contains(QuadFormat.tintIndex(for: id, count: 3)))
    }
  }

  func testTintSpreadsPeopleAcrossThePalette() {
    let used = Set((0..<40).map { QuadFormat.tintIndex(for: "member-\($0)", count: 3) })
    XCTAssertEqual(used, [0, 1, 2])
  }

  func testPostSubtitleSaysWhatThePersonIsDoing() {
    XCTAssertEqual(QuadFormat.subleasing(in: "Westcott"), "Subleasing in Westcott")
    XCTAssertEqual(QuadFormat.subleasing(in: "  "), "Subleasing a place")
  }

  func testTabsAreHomeMatchesInboxYouInOrder() {
    XCTAssertEqual(QuadTab.allCases.map(\.title), ["Home", "Matches", "Inbox", "You"])
    XCTAssertEqual(QuadTab.allCases.map(\.rawValue), [0, 1, 2, 3])
    XCTAssertEqual(QuadTab.inbox.identifier, "tab-inbox")
  }

  func testChecksListWhatStaffHaveAndHaveNotChecked() {
    let rows = QuadFormat.checks(hostName: "Jamie Chen", identity: "verified", lease: "pending")
    XCTAssertEqual(rows.map(\.text), ["Jamie's ID matches their profile", "Lease not checked yet"])
    XCTAssertEqual(rows.map(\.done), [true, false])
  }

  func testChecksUseTheFirstNameAndSayWhenNothingIsChecked() {
    let rows = QuadFormat.checks(hostName: "Alex", identity: "needs_info", lease: "verified")
    XCTAssertEqual(
      rows.map(\.text), ["Alex's ID not checked yet", "Lease for this place reviewed by staff"])
    XCTAssertEqual(rows.map(\.done), [false, true])
  }

  func testFirstNameFallsBackWhenTheNameIsEmpty() {
    XCTAssertEqual(QuadFormat.firstName("Jamie Chen"), "Jamie")
    XCTAssertEqual(QuadFormat.firstName("  "), "this member")
  }

  func testStayLineSaysWhatAndWhen() {
    XCTAssertEqual(
      QuadFormat.stay(roomType: "Entire place", beds: 1, baths: 1.5, start: "2027-01-05", end: "2027-05-15"),
      "Entire place · 1 bed · 1.5 baths · Jan 5 – May 15")
    XCTAssertEqual(
      QuadFormat.stay(roomType: "Private room", beds: 4, baths: 2, start: "2027-01-05", end: "2027-05-15"),
      "Private room · 4 beds · 2 baths · Jan 5 – May 15")
  }
}
