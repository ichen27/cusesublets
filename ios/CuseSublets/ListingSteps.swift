import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The five steps of listing a place, in order. The place is created on the server, unpublished,
/// at the end of `details`, because photos, a scan and documents all attach to a place.
enum ListingStep: Int, CaseIterable {
  case place, details, photos, scan, checks

  var label: String {
    switch self {
    case .place: return "Where"
    case .details: return "Details"
    case .photos: return "Photos"
    case .scan: return "Scan"
    case .checks: return "Checks"
    }
  }

  var title: String {
    switch self {
    case .place: return "Where is your place?"
    case .details: return "Tell people about it"
    case .photos: return "Add photos"
    case .scan: return "Let people look around"
    case .checks: return "Last step: checks"
    }
  }

  /// "Step 4 of 5 · Scan".
  var progress: String { "Step \(rawValue + 1) of \(Self.allCases.count) · \(label)" }
}

/// What someone has typed while listing a place, and the rules for moving on.
struct ListingForm: Equatable {
  var title = ""
  var neighborhood = ""
  var address = ""
  var description = ""
  var price = 800.0
  var beds = 1.0
  var baths = 1.0
  var walkMinutes = 10.0
  var roomType = "Private room"
  var start: Date
  var end: Date
  var amenities: [String] = []
  var lat = 43.037
  var lng = -76.127

  /// The server accepts this many photos for a place.
  static let photoLimit = 12
  /// Offered as one-tap choices; anything else can go in the description.
  static let commonAmenities = [
    "Furnished", "Wi-Fi", "Laundry", "Parking", "Kitchen", "Air conditioning", "Pets welcome",
    "Gym",
  ]

  init(today: Date = Date()) {
    start = today
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = marketplaceTimeZone
    end = calendar.date(byAdding: .day, value: 90, to: today) ?? today
  }

  /// A form restored from a private draft saved on the server.
  init(draft: [String: Any], today: Date = Date()) {
    self.init(today: today)
    title = draft["title"] as? String ?? ""
    neighborhood = draft["neighborhood"] as? String ?? ""
    address = draft["address"] as? String ?? ""
    description = draft["description"] as? String ?? ""
    price = draft["price"] as? Double ?? 800
    beds = draft["beds"] as? Double ?? 1
    baths = draft["baths"] as? Double ?? 1
    walkMinutes = max(1, draft["walkMinutes"] as? Double ?? 10)
    roomType = draft["roomType"] as? String ?? "Private room"
    if let day = draft["startDate"] as? String, !day.isEmpty { start = parseDay(day) }
    if let day = draft["endDate"] as? String, !day.isEmpty { end = parseDay(day) }
    amenities = draft["amenities"] as? [String] ?? []
    lat = draft["lat"] as? Double ?? 43.037
    lng = draft["lng"] as? Double ?? -76.127
  }

  /// What stops this step from moving on, in words for the person, or nil when nothing does.
  func problem(in step: ListingStep, today: Date) -> String? {
    switch step {
    case .place:
      if neighborhood.trimmingCharacters(in: .whitespaces).isEmpty {
        return "Add the neighborhood."
      }
      if address.trimmingCharacters(in: .whitespaces).isEmpty {
        return "Add an approximate address."
      }
      if !(1...120).contains(walkMinutes) { return "The walk to campus must be 1 to 120 minutes." }
      return nil
    case .details:
      if title.trimmingCharacters(in: .whitespaces).isEmpty { return "Give your place a title." }
      if description.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
        return "Describe your place in at least 20 characters."
      }
      if !(price > 0) { return "Set the monthly rent." }
      if isoDay(end) <= isoDay(start) { return "The last day must be after the first." }
      if isoDay(end) <= isoDay(today) { return "The last day must be in the future." }
      return nil
    case .photos, .scan, .checks:
      return nil
    }
  }

  mutating func toggle(amenity: String) {
    if let index = amenities.firstIndex(of: amenity) {
      amenities.remove(at: index)
    } else if amenities.count < 20 {
      amenities.append(amenity)
    }
  }

  /// The one-tap amenities, followed by any this place already has that are not among them.
  var amenityChoices: [String] {
    Self.commonAmenities + amenities.filter { !Self.commonAmenities.contains($0) }
  }

  static func photosLeft(after count: Int) -> Int { max(0, photoLimit - count) }

  /// What the private draft on the server stores, so the steps can be resumed on any device.
  var draft: [String: Any] {
    [
      "title": title, "neighborhood": neighborhood, "address": address, "price": price,
      "beds": beds, "baths": baths, "roomType": roomType, "startDate": isoDay(start),
      "endDate": isoDay(end), "description": description, "amenities": amenities,
      "matterportUrl": "", "videoUrl": "", "images": "", "walkMinutes": walkMinutes,
      "lat": lat, "lng": lng,
    ]
  }

  /// The request that creates the place. It asks the server not to publish yet, so photos and a
  /// scan can be added first. `publishID` makes a repeated request return the same place.
  func payload(publishID: String) -> [String: Any] {
    var body = draft
    body["matterportUrl"] = nil
    body["videoUrl"] = nil
    body["images"] = [String]()
    body["publish"] = false
    body["clientPublishId"] = publishID
    return body
  }
}

/// What the first steps show while the listing steps open.
enum ListingOpening: Equatable {
  /// The answers can be typed.
  case ready
  /// A saved draft is on its way from the server.
  case loadingDraft
  /// The saved draft could not be read.
  case failed

  /// Empty fields shown before a saved draft arrives would be typed into and then replaced by
  /// the draft, so a draft being reopened shows nothing to type in until it has loaded.
  static func choose(resuming: Bool, loaded: Bool, failed: Bool) -> ListingOpening {
    if !resuming || loaded { return .ready }
    return failed ? .failed : .loadingDraft
  }
}

/// What the scan step offers.
enum ScanOffer: Equatable {
  /// The server has not yet said whether it builds tours.
  case checking
  case scanNow
  /// A scan is saved on this iPhone and has not been sent.
  case upload(spots: Int)
  case sent
  /// Scanning cannot happen here; the text says why.
  case unavailable(String)

  static func choose(serverReady: Bool?, phoneReady: Bool, savedSpots: Int, sent: Bool) -> ScanOffer {
    if sent { return .sent }
    guard let serverReady else { return .checking }
    if !serverReady { return .unavailable("360° tours are not set up on this server yet.") }
    if savedSpots > 0 { return .upload(spots: savedSpots) }
    if !phoneReady { return .unavailable("This device cannot scan a room.") }
    return .scanNow
  }
}

/// Photos chosen from the library, made ready for the server.
enum ListingPhoto {
  /// The server refuses a photo larger than this.
  static let byteLimit = 5 * 1024 * 1024
  static let longestSide = 2048

  /// A JPEG no larger than the server accepts, or nil when the data is not a picture. The
  /// picture is redrawn, so what the camera stored inside it, such as where it was taken, is
  /// left behind.
  static func prepared(_ data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: longestSide,
        ] as CFDictionary)
    else { return nil }
    for quality in [0.82, 0.6, 0.4] {
      let output = NSMutableData()
      guard
        let target = CGImageDestinationCreateWithData(
          output, UTType.jpeg.identifier as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImage(
        target, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
      guard CGImageDestinationFinalize(target) else { return nil }
      if output.length <= byteLimit { return output as Data }
    }
    return nil
  }
}
