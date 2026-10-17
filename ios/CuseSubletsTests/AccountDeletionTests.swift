import XCTest

@testable import CuseSublets

final class AccountDeletionTests: XCTestCase {
  @MainActor func testReceiptRecoveryErasesOwnerCapturesWhenSignedOutWithoutErasingAnotherOwner()
    throws
  {
    let owner = "deleted-\(UUID().uuidString)"
    let other = "other-\(UUID().uuidString)"
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let room = base.appendingPathComponent("room-drafts/\(owner).json")
    let photo = PhotoCaptureDraft.folder(owner: owner, listing: "test")
    let otherPhoto = PhotoCaptureDraft.folder(owner: other, listing: "test")
    try fm.createDirectory(at: room.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: photo, withIntermediateDirectories: true)
    try fm.createDirectory(at: otherPhoto, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["ownerId": owner]).write(to: room)
    try JSONSerialization.data(withJSONObject: ["ownerId": owner]).write(
      to: photo.appendingPathComponent("draft.json"))
    try JSONSerialization.data(withJSONObject: ["ownerId": other]).write(
      to: otherPhoto.appendingPathComponent("draft.json"))
    defer {
      try? fm.removeItem(at: room)
      try? fm.removeItem(at: photo)
      try? fm.removeItem(at: otherPhoto)
    }
    let api = APIClient(baseURL: URL(string: "https://deletion-\(UUID().uuidString).example.test"))
    let state = AppState(api: api)
    XCTAssertNil(state.user)
    try state.finishAccountDeletion(
      DeletionReceipt(receipt: String(repeating: "a", count: 64), ownerId: owner))
    XCTAssertFalse(fm.fileExists(atPath: room.path))
    XCTAssertFalse(fm.fileExists(atPath: photo.path))
    XCTAssertTrue(fm.fileExists(atPath: otherPhoto.path))
    state.user = Member(
      id: other, name: "Other", email: "other@example.test", role: "member", identity: "pending")
    try state.finishAccountDeletion(
      DeletionReceipt(receipt: String(repeating: "a", count: 64), ownerId: owner))
    XCTAssertEqual(state.user?.id, other)
  }
  func testDeletedListingPlaceholderStillDecodesForSharedConversation() throws {
    let data = Data(
      """
      {"id":"place","ownerId":"deleted","title":"Deleted listing","neighborhood":"","address":"","lat":0,"lng":0,"price":0,"beds":0,"baths":0,"roomType":"Private room","startDate":"2000-01-01","endDate":"2000-01-02","description":"","amenities":[],"images":[],"status":"removed","leaseStatus":"pending","permissionStatus":"pending","hostName":"Deleted member","hostIdentity":"pending","sample":false}
      """.utf8)
    let listing = try JSONDecoder().decode(Listing.self, from: data)
    XCTAssertEqual(listing.status, "removed")
    XCTAssertEqual(listing.address, "")
  }
}
