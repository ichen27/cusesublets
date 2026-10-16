import CoreLocation
import Foundation

struct Member: Codable, Identifiable {
  let id: String
  var name: String
  let email: String
  let role: String
  let identity: String
  var avatar: String?
  var suspended: Bool?
}
struct SessionResponse: Decodable {
  let user: Member?
  let demo: Bool
}
struct Listing: Codable, Identifiable {
  let id: String
  let ownerId: String
  var title: String
  var neighborhood: String
  var address: String
  var lat: Double
  var lng: Double
  var price: Double
  var beds: Double
  var baths: Double
  var roomType: String
  var startDate: String
  var endDate: String
  var description: String
  var amenities: [String]
  var images: [String]
  var videoUrl: String?
  var matterportUrl: String?
  var status: String
  var leaseStatus: String
  var permissionStatus: String
  var hostName: String
  var hostIdentity: String
  var sample: Bool
  var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}
struct ListingsResponse: Decodable { let listings: [Listing] }
struct ListingResponse: Decodable { let listing: Listing }
struct GeoPoint: Codable {
  var lat: Double
  var lng: Double
}
struct SearchArea: Codable, Identifiable {
  var id: String
  var label: String
  var points: [GeoPoint]
}
struct HousingSearch: Codable, Identifiable {
  let id: String
  let ownerId: String
  let ownerName: String
  let ownerIdentity: String
  var status: String
  var startDate: String
  var endDate: String
  var minBudget: Double?
  var maxBudget: Double
  var minBedrooms: Double?
  var roomType: String
  var requiredAmenities: [String]
  var preferredAmenities: [String]
  var areas: [SearchArea]
  var introduction: String
}
struct SearchesResponse: Decodable { let searches: [HousingSearch] }
struct MySearchResponse: Decodable { let search: HousingSearch? }
struct MatchItem: Decodable, Identifiable {
  let listing: Listing?
  let search: HousingSearch?
  let reasons: [String]
  var id: String { listing?.id ?? search?.id ?? "" }
}
struct MatchesResponse: Decodable { let matches: [MatchItem] }
struct Conversation: Decodable, Identifiable {
  let id: String
  let listingId: String
  let listingTitle: String
  let listingImage: String
  let peerName: String
  let lastMessage: String?
}
struct ConversationsResponse: Decodable { let conversations: [Conversation] }
struct ConversationResponse: Decodable { let conversation: Conversation }
struct ChatMessage: Decodable, Identifiable {
  let id: String
  let senderId: String
  let body: String
  let createdAt: String
}
struct Offer: Decodable, Identifiable {
  let id: String
  let proposedBy: String
  let amount: Double
  let startDate: String
  let endDate: String
  let status: String
  let kind: String
}
struct Booking: Decodable, Identifiable {
  let id: String
  let amount: Double
  let startDate: String
  let endDate: String
  let status: String
  let paymentStatus: String
  let disputeStatus: String
  let disputeReason: String?
  let buyerId: String
}
struct Attachment: Decodable, Identifiable {
  let id: String
  let name: String
}
struct ChatEvent: Decodable, Identifiable {
  let id: String
  let kind: String
  let body: String
  let createdAt: String
}
struct ConversationDetail: Decodable {
  let conversation: Conversation
  let listing: Listing
  let messages: [ChatMessage]
  let offers: [Offer]
  let bookings: [Booking]
  let attachments: [Attachment]
  let events: [ChatEvent]
}
struct Profile: Codable {
  var bio: String
  var phone: String
  var socials: [String: String]
  var avatar: String?
  var photos: [String]
}
struct AccountResponse: Decodable {
  let user: Member
  let profile: Profile
  let identityNote: String?
}
struct PublicMember: Decodable {
  let id: String
  let name: String
  let identity: String
  let bio: String
  let avatar: String?
  let photos: [String]
  let socials: [String: String]
}
struct MemberReview: Decodable, Identifiable {
  let id: String
  let authorName: String
  let rating: Int
  let body: String
}
struct PublicProfileResponse: Decodable {
  let profile: PublicMember
  let listings: [Listing]
  let reviews: [MemberReview]
  let search: HousingSearch?
}
struct SocialComment: Decodable, Identifiable {
  let id: String
  let authorId: String?
  let authorName: String
  let parentId: String?
  let body: String
  let unavailable: Bool
}
struct SocialSummary: Decodable {
  let likeCount: Int
  let commentCount: Int
  let liked: Bool
  let saved: Bool
  let comments: [SocialComment]
  let nextCursor: String?
}
struct CommentsPage: Decodable {
  let comments: [SocialComment]
  let nextCursor: String?
}
struct SavedPost: Decodable, Identifiable {
  let targetType: String
  let targetId: String
  let available: Bool
  var id: String { targetType + targetId }
}
struct SavedResponse: Decodable {
  let items: [SavedPost]
  let nextCursor: String?
}
struct RoomElement: Codable {
  var kind: String
  var dimensions: [Float]
  var transform: [Float]
}
struct RoomLayout: Codable {
  var version = 1
  var elements: [RoomElement]
}
struct RoomScan: Codable, Identifiable {
  let id: String
  let listingId: String
  let name: String
  var published: Bool
  let createdAt: String
  let layout: RoomLayout
}
struct ScansResponse: Decodable { let scans: [RoomScan] }
struct EmptyResponse: Decodable {}
struct APIError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
func dollars(_ value: Double) -> String {
  value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
}
func isoDay(_ date: Date) -> String {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.timeZone = TimeZone(identifier: "America/New_York")
  f.dateFormat = "yyyy-MM-dd"
  return f.string(from: date)
}
func parseDay(_ value: String) -> Date {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.timeZone = TimeZone(identifier: "America/New_York")
  f.dateFormat = "yyyy-MM-dd"
  return f.date(from: value) ?? Date()
}
extension Encodable {
  func dictionary() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] ?? [:]
  }
}
