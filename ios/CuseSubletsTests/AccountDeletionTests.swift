import Security
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
    let room = base.appendingPathComponent("room-drafts/\(owner)-listing.json")
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
  func testReceiptsPreserveBothOwnersAndSurviveRelaunch() throws {
    let account = "receipt-test-\(UUID().uuidString)"
    let store = DeletionReceiptStore(account: account)
    defer { clearReceipt(account) }
    try store.save(.init(receipt: "first", ownerId: "A"))
    try store.save(.init(receipt: "second", ownerId: "B"))
    let reopened = DeletionReceiptStore(account: account)
    XCTAssertEqual(try reopened.read(ownerId: "A")?.receipt, "first")
    XCTAssertEqual(try reopened.read(ownerId: "B")?.receipt, "second")
    try reopened.save(.init(receipt: "first-retry", ownerId: "A"))
    XCTAssertEqual(try reopened.receipts().count, 2)
    XCTAssertEqual(try reopened.read(ownerId: "B")?.receipt, "second")
  }
  func testLegacyReceiptIsPreservedWhenAnotherOwnerRequestsDeletion() throws {
    let account = "legacy-\(UUID().uuidString)"
    defer { clearReceipt(account) }
    let data = try JSONEncoder().encode(DeletionReceipt(receipt: "legacy", ownerId: "A"))
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.ichen27.cusesublets.deletion",
      kSecAttrAccount as String: account, kSecValueData as String: data,
    ]
    XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
    let store = DeletionReceiptStore(account: account)
    try store.save(.init(receipt: "new", ownerId: "B"))
    XCTAssertEqual(try store.read(ownerId: "A")?.receipt, "legacy")
    XCTAssertEqual(try store.receipts().count, 2)
  }
  private func clearReceipt(_ account: String) {
    SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.ichen27.cusesublets.deletion",
        kSecAttrAccount as String: account,
      ] as CFDictionary)
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
