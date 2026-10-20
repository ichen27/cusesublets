import XCTest

@testable import CuseSublets

final class PhotoCaptureTests: XCTestCase {
  func testInterruptedCaptureBeforeFirstFrameExplainsRecovery() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("{}".utf8).write(to: folder.appendingPathComponent("draft.json"))
    XCTAssertThrowsError(try PhotoRecorder.package(folder: folder)) { error in
      XCTAssertEqual(
        error.localizedDescription, "This take has no stable views. Discard it and capture again.")
    }
    try PhotoRecorder.writeManifest([], to: folder)
    XCTAssertThrowsError(try PhotoRecorder.package(folder: folder)) { error in
      XCTAssertTrue(error.localizedDescription.contains("fewer than 30"))
    }
  }
  func testCaptureWaitsForTrackingAndRejectsFastMotion() {
    var policy = CapturePolicy()
    let forward = SIMD3<Float>(0, 0, -1)
    XCTAssertFalse(
      policy.evaluate(time: 0, position: .zero, forward: forward, tracking: false).save)
    XCTAssertTrue(policy.evaluate(time: 1, position: .zero, forward: forward, tracking: true).save)
    XCTAssertFalse(
      policy.evaluate(time: 1.1, position: SIMD3<Float>(1, 0, 0), forward: forward, tracking: true)
        .save)
    XCTAssertFalse(
      policy.evaluate(time: 2, position: SIMD3<Float>(1, 0, 0), forward: forward, tracking: false)
        .save)
    XCTAssertTrue(
      policy.evaluate(time: 3, position: SIMD3<Float>(1, 0, 0), forward: forward, tracking: true)
        .save)
  }
  func testRecoveryDirectoriesAreScopedToOwnerAndListing() {
    let first = PhotoCaptureDraft.folder(owner: "one", listing: "room")
    XCTAssertEqual(first, PhotoCaptureDraft.folder(owner: "one", listing: "room"))
    XCTAssertNotEqual(first, PhotoCaptureDraft.folder(owner: "two", listing: "room"))
    XCTAssertNotEqual(first, PhotoCaptureDraft.folder(owner: "one", listing: "other"))
    XCTAssertFalse(
      PhotoCaptureDraft.folder(owner: "../", listing: "../").lastPathComponent.contains("."))
  }
  func testArchiveRejectsTraversalAndWritesPaddedUSTAR() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = folder.appendingPathComponent("source")
    try Data("{}".utf8).write(to: input)
    let output = folder.appendingPathComponent("capture")
    XCTAssertThrowsError(
      try CaptureArchive.write(entries: [("../manifest.json", input)], to: output))
    XCTAssertThrowsError(
      try CaptureArchive.write(
        entries: [("manifest.json", input), ("manifest.json", input)], to: output))
    try CaptureArchive.write(entries: [("manifest.json", input)], to: output)
    let bytes = try Data(contentsOf: output)
    XCTAssertEqual(bytes.count, 2048)
    XCTAssertEqual(String(data: bytes[257..<262], encoding: .utf8), "ustar")
    XCTAssertEqual(bytes.suffix(1024), Data(repeating: 0, count: 1024))
  }
}
