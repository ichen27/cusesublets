import Foundation
import MapKit

struct DiscoveryFilters {
  var query = ""
  var maxPrice: Double?
  var roomType = ""
  var startDate = ""
  var endDate = ""
  var furnished = false
  var checked = false
  var tour = false
  var validDates: Bool { startDate.isEmpty || endDate.isEmpty || startDate < endDate }

  func includes(_ l: Listing, today: String = isoDay(Date())) -> Bool {
    validDates && l.status == "approved" && l.endDate > today
      && (query.isEmpty
        || "\(l.title) \(l.neighborhood) \(l.description)".localizedCaseInsensitiveContains(query))
      && (maxPrice == nil || l.price <= maxPrice!)
      && (roomType.isEmpty || l.roomType == roomType)
      && (startDate.isEmpty || (l.startDate <= startDate && startDate < l.endDate))
      && (endDate.isEmpty || (l.endDate >= endDate && endDate > l.startDate))
      && (!furnished || l.amenities.contains("Furnished"))
      && (!checked || (l.leaseStatus == "verified" && l.permissionStatus == "verified"))
      && (!tour || !(l.matterportUrl ?? "").isEmpty)
  }
  func includes(_ s: HousingSearch, today: String = isoDay(Date())) -> Bool {
    validDates && s.status == "active" && s.endDate > today
      && (query.isEmpty
        || ([s.ownerName, s.introduction] + s.areas.map(\.label)).joined(separator: " ")
          .localizedCaseInsensitiveContains(query))
      && (maxPrice == nil || (s.minBudget ?? 0) <= maxPrice!)
      && (roomType.isEmpty || s.roomType == "Any" || s.roomType == roomType)
      && (startDate.isEmpty || s.endDate > startDate)
      && (endDate.isEmpty || s.startDate < endDate)
      && (!furnished || (s.requiredAmenities + s.preferredAmenities).contains("Furnished"))
  }
}

struct DiscoveryBounds {
  var south: Double
  var north: Double
  var west: Double
  var east: Double
  init(south: Double, north: Double, west: Double, east: Double) {
    self.south = south
    self.north = north
    self.west = west
    self.east = east
  }
  init(_ region: MKCoordinateRegion) {
    south = region.center.latitude - region.span.latitudeDelta / 2
    north = region.center.latitude + region.span.latitudeDelta / 2
    west = region.center.longitude - region.span.longitudeDelta / 2
    east = region.center.longitude + region.span.longitudeDelta / 2
  }
  func contains(_ point: GeoPoint) -> Bool {
    point.lat >= south && point.lat <= north && point.lng >= west && point.lng <= east
  }
  func intersects(_ area: SearchArea) -> Bool {
    guard area.points.count >= 3 else { return false }
    let corners = [
      GeoPoint(lat: south, lng: west), GeoPoint(lat: south, lng: east),
      GeoPoint(lat: north, lng: east), GeoPoint(lat: north, lng: west),
    ]
    if area.points.contains(where: contains) || corners.contains(where: { area.contains($0) }) {
      return true
    }
    for i in area.points.indices {
      for j in corners.indices {
        if segmentsIntersect(
          area.points[i], area.points[(i + 1) % area.points.count],
          corners[j], corners[(j + 1) % corners.count])
        {
          return true
        }
      }
    }
    return false
  }
}
private func cross(_ a: GeoPoint, _ b: GeoPoint, _ c: GeoPoint) -> Double {
  (b.lng - a.lng) * (c.lat - a.lat) - (b.lat - a.lat) * (c.lng - a.lng)
}
private func onSegment(_ a: GeoPoint, _ b: GeoPoint, _ p: GeoPoint) -> Bool {
  abs(cross(a, b, p)) < 1e-10 && p.lat >= min(a.lat, b.lat) - 1e-10
    && p.lat <= max(a.lat, b.lat) + 1e-10 && p.lng >= min(a.lng, b.lng) - 1e-10
    && p.lng <= max(a.lng, b.lng) + 1e-10
}
private func segmentsIntersect(_ a: GeoPoint, _ b: GeoPoint, _ c: GeoPoint, _ d: GeoPoint) -> Bool {
  if onSegment(a, b, c) || onSegment(a, b, d) || onSegment(c, d, a) || onSegment(c, d, b) {
    return true
  }
  return (cross(a, b, c) > 0) != (cross(a, b, d) > 0)
    && (cross(c, d, a) > 0) != (cross(c, d, b) > 0)
}
extension SearchArea {
  func contains(_ point: GeoPoint) -> Bool {
    guard points.count >= 3 else { return false }
    var inside = false
    for i in points.indices {
      let a = points[i]
      let b = points[(i + 1) % points.count]
      if onSegment(a, b, point) { return true }
      if (a.lat > point.lat) != (b.lat > point.lat)
        && point.lng < (b.lng - a.lng) * (point.lat - a.lat) / (b.lat - a.lat) + a.lng
      {
        inside.toggle()
      }
    }
    return inside
  }
}

// Mirrors shared/matching.ts housing eligibility; the server rechecks all contact actions.
func housingFits(_ l: Listing, _ s: HousingSearch, today: String = isoDay(Date())) -> Bool {
  let offered = Set(l.amenities.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
  return l.status == "approved" && s.status == "active" && l.ownerId != s.ownerId
    && l.endDate > today && s.endDate > today && l.startDate <= s.startDate
    && l.endDate >= s.endDate
    && l.price <= s.maxBudget && l.price >= (s.minBudget ?? 0)
    && (s.roomType == "Any" || l.roomType == s.roomType)
    && (s.roomType != "Entire place" || l.beds >= (s.minBedrooms ?? 0))
    && s.areas.contains { $0.contains(.init(lat: l.lat, lng: l.lng)) }
    && s.requiredAmenities.allSatisfy {
      offered.contains($0.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

enum DiscoveryPost: Identifiable {
  case listing(Listing)
  case search(HousingSearch)
  var id: String {
    switch self {
    case .listing(let l): return "listing:" + l.id
    case .search(let s): return "search:" + s.id
    }
  }
  var createdAt: String {
    switch self {
    case .listing(let l): return l.createdAt ?? ""
    case .search(let s): return s.createdAt ?? ""
    }
  }
  func fits(search: HousingSearch?, listings: [Listing]) -> Bool {
    switch self {
    case .listing(let l): return search.map { housingFits(l, $0) } ?? false
    case .search(let s): return listings.contains { housingFits($0, s) }
    }
  }
}
