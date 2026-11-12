import XCTest

@testable import CuseSublets

final class SpotTakeTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

  private func record(_ index: Int, role: String = "walk", spot: Int? = nil) -> CaptureFrameRecord
  {
    var r = CaptureFrameRecord(
      filePath: String(format: "images/%05d.jpg", index), timestamp: Double(index), width: 1440,
      height: 1080, fx: 1100, fy: 1100, cx: 720, cy: 540,
      transformMatrix: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]], points: [])
    r.role = role
    r.spot = spot
    return r
  }

  /// Writes frames to disk the way CaptureWriter does: image first, then its record.
  private func write(_ frames: [CaptureFrameRecord]) throws {
    var lines = Data()
    for frame in frames {
      try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: folder.appendingPathComponent(frame.filePath))
      lines += try JSONEncoder().encode(frame) + Data("\n".utf8)
    }
    try lines.write(to: folder.appendingPathComponent(PhotoRecorder.recordsName))
  }

  private func spot(_ number: Int, slices: [Int]) -> SpotRecord {
    SpotRecord(
      spot: number, slices: slices.map { String(format: "images/%05d.jpg", $0) },
      position: [0.5, 0, -1], floorY: -1.4, startYaw: 0.25, exposureDuration: 1.0 / 60, iso: 400)
  }

  func testRecordWithoutRoleDecodesAsWalk() throws {
    let json = """
      {"file_path":"images/00000.jpg","timestamp":1,"width":1920,"height":1440,"fx":1,"fy":1,
      "cx":1,"cy":1,"transform_matrix":[[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],"points":[]}
      """
    let decoded = try JSONDecoder().decode(CaptureFrameRecord.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.role, "walk")
    XCTAssertNil(decoded.spot)
  }

  func testSliceRecordRoundTrips() throws {
    let slice = record(3, role: "slice", spot: 2)
    let data = try JSONEncoder().encode(slice)
    XCTAssertEqual(try JSONDecoder().decode(CaptureFrameRecord.self, from: data), slice)
    XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"spot\":2"))
  }

  func testSpotRecordRoundTripsWithSnakeCaseKeys() throws {
    let data = try JSONEncoder().encode(spot(1, slices: [0, 1]))
    let text = String(decoding: data, as: UTF8.self)
    for key in ["\"floor_y\"", "\"start_yaw\"", "\"exposure_duration\"", "\"iso\"", "\"slices\""] {
      XCTAssertTrue(text.contains(key), key)
    }
    XCTAssertEqual(try JSONDecoder().decode(SpotRecord.self, from: data), spot(1, slices: [0, 1]))
  }

  func testRecoveryDropsUnfinishedSpot() throws {
    // Spot 1 finished (slices 1–2); spot 2's slices 4–5 were written but the app was killed
    // before its record.
    try write([
      record(0), record(1, role: "slice", spot: 1), record(2, role: "slice", spot: 1), record(3),
      record(4, role: "slice", spot: 2), record(5, role: "slice", spot: 2),
    ])
    try SpotTake.appendSpot(spot(1, slices: [1, 2]), to: folder)
    let frames = try PhotoRecorder.savedFrames(in: folder)
    XCTAssertEqual(SpotTake.savedSpots(in: folder, frames: frames).map(\.spot), [1])
    _ = try SpotTake.package(folder: folder)
    let manifest = try JSONDecoder().decode(
      CaptureManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    // The unfinished spot's frames still go to the server, for the mesh only.
    XCTAssertEqual(manifest.frames.count, 6)
    XCTAssertEqual(manifest.spots?.map(\.spot), [1])
  }

  func testSpotWithMissingSliceIsNotSaved() throws {
    try write([record(0, role: "slice", spot: 1)])
    try SpotTake.appendSpot(spot(1, slices: [0, 1]), to: folder)
    XCTAssertTrue(
      SpotTake.savedSpots(in: folder, frames: try PhotoRecorder.savedFrames(in: folder)).isEmpty)
  }

  func testDeletedSpotIsNotSaved() throws {
    try write([record(0, role: "slice", spot: 1), record(1, role: "slice", spot: 2)])
    try SpotTake.appendSpot(spot(1, slices: [0]), to: folder)
    try SpotTake.appendSpot(spot(2, slices: [1]), to: folder)
    try SpotTake.deleteSpot(1, in: folder)
    let frames = try PhotoRecorder.savedFrames(in: folder)
    XCTAssertEqual(SpotTake.savedSpots(in: folder, frames: frames).map(\.spot), [2])
  }

  func testPackagingNeedsOneSpot() throws {
    try write([record(0)])
    XCTAssertThrowsError(try SpotTake.package(folder: folder)) { error in
      XCTAssertEqual(error.localizedDescription, "Capture at least one spot before generating.")
    }
  }

  func testManifestV2HasCaptureAndSpots() throws {
    try write([record(0), record(1, role: "slice", spot: 1)])
    try SpotTake.appendSpot(spot(1, slices: [1]), to: folder)
    let archive = try SpotTake.package(folder: folder)
    XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    let json = try JSONSerialization.jsonObject(
      with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as! [String: Any]
    XCTAssertEqual(json["schema_version"] as? Int, 2)
    XCTAssertEqual(json["capture"] as? String, "spots")
    XCTAssertEqual((json["spots"] as? [Any])?.count, 1)
  }

  func testOldManifestWithoutCaptureStillDecodes() throws {
    let json = #"{"schema_version":1,"source":"arkit","coordinate_system":"x","capability":"camera","frames":[]}"#
    let manifest = try JSONDecoder().decode(CaptureManifest.self, from: Data(json.utf8))
    XCTAssertEqual(manifest.capture, "splat")
    XCTAssertNil(manifest.spots)
  }

  func testBudgetRefusesSpotThatCannotFit() {
    var budget = CaptureBudget(
      maximumViews: SpotTake.maximumViews, archiveLimit: SpotTake.archiveLimit)
    XCTAssertTrue(budget.canFit(views: SpotLayout.standard.count, averageImage: 400_000))
    while budget.archiveBytes < 95 * 1024 * 1024 { budget.record(image: 1_000_000, metadata: 4_000) }
    XCTAssertFalse(budget.canFit(views: SpotLayout.standard.count, averageImage: 400_000))
  }

  func testSpotLimitsMatchTheDesign() {
    XCTAssertEqual(SpotTake.maximumSpots, 8)
    XCTAssertEqual(SpotTake.maximumWalkFrames, 90)
    XCTAssertEqual(SpotTake.archiveLimit, 96 * 1024 * 1024)
    XCTAssertEqual(SpotTake.maximumViews, 8 * 29 + 90)
  }

  func testSplatBudgetUnchanged() {
    let budget = CaptureBudget()
    XCTAssertEqual(budget.limit, 64 * 1024 * 1024)
    XCTAssertEqual(budget.maximumViews, 180)
  }

  func testSpotFolderIsSeparateFromWalkAroundFolder() {
    XCTAssertNotEqual(
      SpotTake.folder(owner: "a", listing: "b"), PhotoCaptureDraft.folder(owner: "a", listing: "b"))
    XCTAssertEqual(
      SpotTake.folder(owner: "a", listing: "b").lastPathComponent,
      PhotoCaptureDraft.folder(owner: "a", listing: "b").lastPathComponent)
  }
}
