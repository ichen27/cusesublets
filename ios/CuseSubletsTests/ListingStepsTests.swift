import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import CuseSublets

final class ListingStepsTests: XCTestCase {
  private let today = parseDay("2026-11-16")

  private func filled() -> ListingForm {
    var form = ListingForm(today: today)
    form.neighborhood = "Westcott"
    form.address = "Near Westcott Street"
    form.title = "Sunny room for spring"
    form.description = "Furnished room with a desk and a big window."
    return form
  }

  func testThereAreFiveStepsInOrder() {
    XCTAssertEqual(
      ListingStep.allCases.map(\.label), ["Where", "Details", "Photos", "Scan", "Checks"])
    XCTAssertEqual(ListingStep.scan.progress, "Step 4 of 5 · Scan")
    XCTAssertEqual(ListingStep.place.progress, "Step 1 of 5 · Where")
  }

  func testANewFormStartsTodayAndRunsNinetyDays() {
    let form = ListingForm(today: today)
    XCTAssertEqual(isoDay(form.start), "2026-11-16")
    XCTAssertEqual(isoDay(form.end), "2027-02-14")
  }

  func testWhereNeedsANeighborhoodAndAnAddress() {
    var form = filled()
    XCTAssertNil(form.problem(in: .place, today: today))
    form.neighborhood = "  "
    XCTAssertEqual(form.problem(in: .place, today: today), "Add the neighborhood.")
    form.neighborhood = "Westcott"
    form.address = ""
    XCTAssertEqual(form.problem(in: .place, today: today), "Add an approximate address.")
  }

  func testWhereKeepsTheWalkWithinTwoHours() {
    var form = filled()
    form.walkMinutes = 0
    XCTAssertEqual(
      form.problem(in: .place, today: today), "The walk to campus must be 1 to 120 minutes.")
    form.walkMinutes = 121
    XCTAssertEqual(
      form.problem(in: .place, today: today), "The walk to campus must be 1 to 120 minutes.")
  }

  func testDetailsNeedATitleAndARealDescription() {
    var form = filled()
    XCTAssertNil(form.problem(in: .details, today: today))
    form.title = ""
    XCTAssertEqual(form.problem(in: .details, today: today), "Give your place a title.")
    form.title = "Sunny room"
    form.description = "Too short"
    XCTAssertEqual(
      form.problem(in: .details, today: today), "Describe your place in at least 20 characters.")
  }

  func testDetailsNeedRentAndDatesThatMakeSense() {
    var form = filled()
    form.price = 0
    XCTAssertEqual(form.problem(in: .details, today: today), "Set the monthly rent.")
    form.price = 800
    form.end = form.start
    XCTAssertEqual(
      form.problem(in: .details, today: today), "The last day must be after the first.")
    form.start = parseDay("2026-01-05")
    form.end = parseDay("2026-05-15")
    XCTAssertEqual(
      form.problem(in: .details, today: today), "The last day must be in the future.")
  }

  func testLaterStepsNeverBlock() {
    let empty = ListingForm(today: today)
    for step in [ListingStep.photos, .scan, .checks] {
      XCTAssertNil(empty.problem(in: step, today: today))
    }
  }

  func testAmenitiesToggleOnAndOffInTheOrderChosen() {
    var form = filled()
    form.toggle(amenity: "Parking")
    form.toggle(amenity: "Furnished")
    XCTAssertEqual(form.amenities, ["Parking", "Furnished"])
    form.toggle(amenity: "Parking")
    XCTAssertEqual(form.amenities, ["Furnished"])
  }

  func testAmenityChoicesKeepOnesFromAnOlderDraftThatAreNotOnTheList() {
    var form = filled()
    XCTAssertEqual(form.amenityChoices, ListingForm.commonAmenities)
    form.amenities = ["Dishwasher", "Furnished"]
    XCTAssertEqual(form.amenityChoices, ListingForm.commonAmenities + ["Dishwasher"])
  }

  func testPhotosLeftCountsDownFromTwelveAndStopsAtNone() {
    XCTAssertEqual(ListingForm.photosLeft(after: 0), 12)
    XCTAssertEqual(ListingForm.photosLeft(after: 10), 2)
    XCTAssertEqual(ListingForm.photosLeft(after: 15), 0)
  }

  func testThePayloadCarriesWhatTheServerNeedsAndAsksNotToPublishYet() {
    var form = filled()
    form.toggle(amenity: "Furnished")
    let body = form.payload(publishID: "0b0e9d3c-1f0a-4e2b-9a43-0d6b2f6d2a11")
    XCTAssertEqual(body["title"] as? String, "Sunny room for spring")
    XCTAssertEqual(body["startDate"] as? String, "2026-11-16")
    XCTAssertEqual(body["amenities"] as? [String], ["Furnished"])
    XCTAssertEqual(body["publish"] as? Bool, false)
    XCTAssertEqual(body["clientPublishId"] as? String, "0b0e9d3c-1f0a-4e2b-9a43-0d6b2f6d2a11")
    XCTAssertEqual((body["images"] as? [String])?.count, 0)
  }

  func testScanIsOfferedWhenTheServerAndThePhoneCanDoIt() {
    XCTAssertEqual(
      ScanOffer.choose(serverReady: true, phoneReady: true, savedSpots: 0, sent: false), .scanNow)
  }

  func testASavedScanIsOfferedForUpload() {
    XCTAssertEqual(
      ScanOffer.choose(serverReady: true, phoneReady: true, savedSpots: 4, sent: false),
      .upload(spots: 4))
  }

  func testASentScanNeedsNothingMore() {
    XCTAssertEqual(
      ScanOffer.choose(serverReady: true, phoneReady: true, savedSpots: 0, sent: true), .sent)
  }

  func testScanOffersNothingUntilTheServerHasAnswered() {
    XCTAssertEqual(
      ScanOffer.choose(serverReady: nil, phoneReady: true, savedSpots: 2, sent: false), .checking)
  }

  func testScanSaysWhyItCannotBeDoneHere() {
    XCTAssertEqual(
      ScanOffer.choose(serverReady: false, phoneReady: true, savedSpots: 3, sent: false),
      .unavailable("360° tours are not set up on this server yet."))
    XCTAssertEqual(
      ScanOffer.choose(serverReady: true, phoneReady: false, savedSpots: 0, sent: false),
      .unavailable("This device cannot scan a room."))
  }

  // MARK: Photos

  private func picture(width: Int, height: Int, gps: Bool = false) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: width, height: height), format: format
    ).image { context in
      // Stripes, so the picture does not compress to almost nothing.
      for x in stride(from: 0, to: width, by: 8) {
        UIColor(hue: CGFloat(x % 97) / 97, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
        context.fill(CGRect(x: x, y: 0, width: 8, height: height))
      }
    }
    let data = NSMutableData()
    let target = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
    if gps {
      properties[kCGImagePropertyGPSDictionary] = [
        kCGImagePropertyGPSLatitude: 43.037, kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 76.127, kCGImagePropertyGPSLongitudeRef: "W",
      ]
    }
    CGImageDestinationAddImage(target, image.cgImage!, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(target))
    return data as Data
  }

  private func properties(_ data: Data) -> [CFString: Any] {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
  }

  func testALargePhotoIsShrunkToFitTheServer() throws {
    let prepared = try XCTUnwrap(ListingPhoto.prepared(picture(width: 4000, height: 3000)))
    let info = properties(prepared)
    XCTAssertEqual(info[kCGImagePropertyPixelWidth] as? Int, 2048)
    XCTAssertEqual(info[kCGImagePropertyPixelHeight] as? Int, 1536)
    XCTAssertLessThanOrEqual(prepared.count, ListingPhoto.byteLimit)
    XCTAssertEqual(Array(prepared.prefix(2)), [0xFF, 0xD8], "The server expects a JPEG")
  }

  func testASmallPhotoKeepsItsSize() throws {
    let prepared = try XCTUnwrap(ListingPhoto.prepared(picture(width: 800, height: 600)))
    XCTAssertEqual(properties(prepared)[kCGImagePropertyPixelWidth] as? Int, 800)
  }

  func testAPreparedPhotoDoesNotSayWhereItWasTaken() throws {
    let original = picture(width: 800, height: 600, gps: true)
    XCTAssertNotNil(properties(original)[kCGImagePropertyGPSDictionary], "The fixture has a location")
    let prepared = try XCTUnwrap(ListingPhoto.prepared(original))
    XCTAssertNil(properties(prepared)[kCGImagePropertyGPSDictionary])
  }

  func testSomethingThatIsNotAPictureIsRefused() {
    XCTAssertNil(ListingPhoto.prepared(Data("not a picture".utf8)))
  }

  // MARK: Opening

  func testANewPlaceCanBeTypedStraightAway() {
    XCTAssertEqual(ListingOpening.choose(resuming: false, loaded: false, failed: false), .ready)
  }

  /// Empty fields shown before a saved draft arrives would be typed into and then replaced.
  func testASavedDraftIsNotShownAsEmptyFieldsWhileItLoads() {
    XCTAssertEqual(
      ListingOpening.choose(resuming: true, loaded: false, failed: false), .loadingDraft)
    XCTAssertEqual(ListingOpening.choose(resuming: true, loaded: true, failed: false), .ready)
  }

  func testASavedDraftThatDoesNotLoadSaysSo() {
    XCTAssertEqual(ListingOpening.choose(resuming: true, loaded: false, failed: true), .failed)
  }
}
