import XCTest

@testable import CuseSublets

final class DiscoveryTests: XCTestCase {
  func testListingDraftBoundsRejectInvalidNumbersAndLocation() throws {
    try ListingInputValidation.validate(
      price: 20000, beds: 20, baths: 20, walkMinutes: 120, lat: 42.9, lng: -75.95)
    for price in [Double.nan, Double.infinity, -1, 20001] {
      XCTAssertThrowsError(
        try ListingInputValidation.validate(
          price: price, beds: 1, baths: 1, walkMinutes: 10, lat: 43, lng: -76.1))
    }
    XCTAssertThrowsError(
      try ListingInputValidation.validate(
        price: 900, beds: 1, baths: 1, walkMinutes: 121, lat: 43, lng: -76.1))
    XCTAssertThrowsError(
      try ListingInputValidation.validate(
        price: 900, beds: 1, baths: 1, walkMinutes: 10, lat: 44, lng: -76.1))
  }
  private let today = "2026-01-01"
  private func listing() -> Listing {
    Listing(
      id: "place", ownerId: "host", title: "A room", neighborhood: "Westcott",
      address: "Approximate",
      lat: 43, lng: -76.1, price: 900, beds: 2, baths: 1, roomType: "Entire place",
      startDate: "2026-02-01", endDate: "2026-06-01", description: "Near the library",
      amenities: ["Furnished", "Laundry"], images: [], status: "approved", leaseStatus: "pending",
      permissionStatus: "pending", hostName: "Host", hostIdentity: "verified", sample: true)
  }
  private func search(owner: String = "seeker") -> HousingSearch {
    HousingSearch(
      id: "search", ownerId: owner, ownerName: "Seeker", ownerIdentity: "pending",
      status: "active", startDate: "2026-03-01", endDate: "2026-05-01", minBudget: 700,
      maxBudget: 1000,
      minBedrooms: 2, roomType: "Entire place", requiredAmenities: ["Laundry"],
      preferredAmenities: ["Furnished"],
      areas: [
        .init(
          id: "area", label: "Home",
          points: [
            .init(lat: 42.99, lng: -76.11), .init(lat: 43.01, lng: -76.11),
            .init(lat: 43.01, lng: -76.09), .init(lat: 42.99, lng: -76.09),
          ])
      ], introduction: "A quiet place")
  }
  func testStayMustFitListingButPeopleNeedOverlappingDates() {
    var f = DiscoveryFilters()
    f.startDate = "2026-01-15"
    f.endDate = "2026-04-01"
    XCTAssertFalse(f.includes(listing(), today: today))
    XCTAssertTrue(f.includes(search(), today: today))
    f.startDate = "2026-03-01"
    f.endDate = "2026-05-01"
    XCTAssertTrue(f.includes(listing(), today: today))
    f.endDate = f.startDate
    XCTAssertFalse(f.includes(listing(), today: today))
    XCTAssertFalse(f.includes(search(), today: today))
  }
  func testCheckFilterRequiresBothPropertyChecksAndNoDefaultBudgetCap() {
    var l = listing()
    l.price = 6000
    var f = DiscoveryFilters()
    XCTAssertTrue(f.includes(l, today: today))
    f.checked = true
    XCTAssertFalse(f.includes(l, today: today))
    l.leaseStatus = "verified"
    XCTAssertFalse(f.includes(l, today: today))
    l.permissionStatus = "verified"
    XCTAssertTrue(f.includes(l, today: today))
    f.maxPrice = 5000
    XCTAssertFalse(f.includes(l, today: today))
  }
  func testPeopleBudgetUsesMinimumAndExpiredPostsAreExcluded() {
    var f = DiscoveryFilters()
    f.maxPrice = 800
    XCTAssertTrue(f.includes(search(), today: today))
    f.maxPrice = 600
    XCTAssertFalse(f.includes(search(), today: today))
    XCTAssertFalse(DiscoveryFilters().includes(search(), today: "2026-05-01"))
    XCTAssertFalse(DiscoveryFilters().includes(listing(), today: "2026-06-01"))
  }
  func testViewportIntersectionsIncludeCrossingEdgesAndEnclosedMap() {
    let b = DiscoveryBounds(south: 0, north: 1, west: 0, east: 1)
    let crossing = SearchArea(
      id: "cross", label: "Crossing",
      points: [
        .init(lat: 0.4, lng: -1), .init(lat: 0.6, lng: -1),
        .init(lat: 0.6, lng: 2), .init(lat: 0.4, lng: 2),
      ])
    XCTAssertTrue(b.intersects(crossing))
    let enclosing = SearchArea(
      id: "around", label: "Around",
      points: [
        .init(lat: -1, lng: -1), .init(lat: 2, lng: -1), .init(lat: 2, lng: 2),
        .init(lat: -1, lng: 2),
      ])
    XCTAssertTrue(b.intersects(enclosing))
    XCTAssertFalse(b.intersects(search().areas[0]))
    XCTAssertTrue(enclosing.contains(.init(lat: -1, lng: 0)))
  }
  func testFitRejectsOwnListingMissingRequirementsAndWrongArea() {
    var l = listing()
    var s = search()
    XCTAssertTrue(housingFits(l, s, today: today))
    XCTAssertFalse(housingFits(l, search(owner: "host"), today: today))
    s.requiredAmenities = ["Parking"]
    XCTAssertFalse(housingFits(l, s, today: today))
    s = search()
    l.beds = 1
    XCTAssertFalse(housingFits(l, s, today: today))
    l = listing()
    l.lat = 44
    XCTAssertFalse(housingFits(l, s, today: today))
    l = listing()
    l.price = 600
    XCTAssertFalse(housingFits(l, s, today: today))
  }
}
