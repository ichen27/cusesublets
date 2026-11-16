import XCTest
import simd

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
    XCTAssertEqual(SpotTake.maximumViews, 8 * 6 + 90)
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

  func testTakeWithoutFinishedSpotIsDiscarded() throws {
    // Walk frames and half a turn, but no finished spot: nothing worth keeping on the phone.
    try write([record(0), record(1, role: "slice", spot: 1)])
    try Data("{}".utf8).write(to: folder.appendingPathComponent("draft.json"))
    XCTAssertTrue(try SpotTake.discardIfEmpty(folder: folder))
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
  }

  func testTakeWithAFinishedSpotIsKept() throws {
    try write([record(0, role: "slice", spot: 1)])
    try SpotTake.appendSpot(spot(1, slices: [0]), to: folder)
    XCTAssertFalse(try SpotTake.discardIfEmpty(folder: folder))
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
  }

  func testAMovedSpotKeepsItsHeightAndSlices() throws {
    try write([record(0, role: "slice", spot: 1), record(1, role: "slice", spot: 2)])
    try SpotTake.appendSpot(spot(1, slices: [0]), to: folder)
    try SpotTake.appendSpot(spot(2, slices: [1]), to: folder)
    try SpotTake.moveSpot(2, to: SIMD2(3, -4.5), in: folder)
    let saved = SpotTake.savedSpots(in: folder, frames: try PhotoRecorder.savedFrames(in: folder))
    XCTAssertEqual(saved.map(\.spot), [1, 2])
    XCTAssertEqual(saved[0].position, [0.5, 0, -1])
    XCTAssertNil(saved[0].moved)
    XCTAssertEqual(saved[1].position, [3, 0, -4.5])
    XCTAssertEqual(saved[1].moved, true)
    XCTAssertEqual(saved[1].slices, ["images/00001.jpg"])
  }

  func testMovingAMissingSpotOrToNowhereFails() throws {
    try write([record(0, role: "slice", spot: 1)])
    try SpotTake.appendSpot(spot(1, slices: [0]), to: folder)
    XCTAssertThrowsError(try SpotTake.moveSpot(7, to: SIMD2(1, 1), in: folder))
    XCTAssertThrowsError(try SpotTake.moveSpot(1, to: SIMD2(.nan, 1), in: folder))
  }

  func testMapLayoutTurnsADragBackIntoMetres() {
    let layout = SpotMapLayout(
      points: [SIMD2(-1, -2), SIMD2(3, 1)], size: CGSize(width: 300, height: 200))
    for place in [SIMD2<Float>(-1, -2), SIMD2(3, 1), SIMD2(0.4, -0.7)] {
      let back = layout.world(layout.screen(place))
      XCTAssertEqual(simd_distance(back, place), 0, accuracy: 1e-4)
    }
    // Everything fits, with the middle of the room in the middle of the map.
    XCTAssertEqual(layout.screen(SIMD2(1, -0.5)), CGPoint(x: 150, y: 100))
    XCTAssertGreaterThan(layout.screen(SIMD2(-1, -2)).x, 0)
    XCTAssertLessThan(layout.screen(SIMD2(3, 1)).x, 300)
  }

  func testAZoomedAndMovedMapStillTurnsADragBackIntoMetres() {
    let size = CGSize(width: 300, height: 200)
    let pose = SpotMapPose(zoom: 2.5, pan: CGSize(width: 40, height: -25))
    let layout = SpotMapLayout(points: [SIMD2(-1, -2), SIMD2(3, 1)], size: size, pose: pose)
    for place in [SIMD2<Float>(-1, -2), SIMD2(3, 1), SIMD2(0.4, -0.7)] {
      XCTAssertEqual(simd_distance(layout.world(layout.screen(place)), place), 0, accuracy: 1e-4)
    }
    // The middle of the room moves with the map, and a metre is drawn 2.5 times as long.
    let fitted = SpotMapLayout(points: [SIMD2(-1, -2), SIMD2(3, 1)], size: size)
    XCTAssertEqual(layout.screen(SIMD2(1, -0.5)), CGPoint(x: 190, y: 75))
    XCTAssertEqual(layout.metre, fitted.metre * 2.5, accuracy: 1e-6)
  }

  func testPinchingKeepsThePlaceUnderTheFingersStill() {
    let size = CGSize(width: 300, height: 200)
    let points = [SIMD2<Float>(-1, -2), SIMD2(3, 1)]
    let start = SpotMapPose(zoom: 1.5, pan: CGSize(width: 10, height: 20))
    let fingers = CGPoint(x: 220, y: 60)
    let place = SpotMapLayout(points: points, size: size, pose: start).world(fingers)
    let zoomed = start.zoomed(by: 2, about: fingers, in: size)
    XCTAssertEqual(zoomed.zoom, 3, accuracy: 1e-6)
    let after = SpotMapLayout(points: points, size: size, pose: zoomed).screen(place)
    XCTAssertEqual(after.x, fingers.x, accuracy: 1e-3)
    XCTAssertEqual(after.y, fingers.y, accuracy: 1e-3)
  }

  func testTheMapCannotBeZoomedOrMovedOutOfReach() {
    let size = CGSize(width: 300, height: 200)
    let centre = CGPoint(x: 150, y: 100)
    XCTAssertEqual(SpotMapPose().zoomed(by: 100, about: centre, in: size).zoom, SpotMapPose.zoomRange.upperBound)
    XCTAssertEqual(SpotMapPose().zoomed(by: 0.01, about: centre, in: size).zoom, SpotMapPose.zoomRange.lowerBound)
    // However far it is dragged, the middle of the fitted map stays on screen.
    let far = SpotMapPose().moved(by: CGSize(width: 5000, height: -5000), in: size)
    XCTAssertEqual(far.pan, CGSize(width: 150, height: -100))
    XCTAssertEqual(SpotMapPose().moved(by: CGSize(width: 30, height: 12), in: size).pan, CGSize(width: 30, height: 12))
  }

  func testASpotRecordsHowLongItsCameraAndSketchTook() throws {
    var record = spot(1, slices: [0])
    record.cameraDelay = 0.8
    record.sketchDelay = 2.5
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    XCTAssertEqual(json["camera_delay"] as? Double, 0.8)
    XCTAssertEqual(json["sketch_delay"] as? Double, 2.5)
    // Takes saved by earlier builds have neither.
    let old = try JSONEncoder().encode(spot(2, slices: [0]))
    XCTAssertNil(try JSONDecoder().decode(SpotRecord.self, from: old).cameraDelay)
  }

  func testTheMapGridKeepsItsLinesApart() {
    // A line every metre while a metre is wide enough on screen, then every 2, 5, 10 metres.
    XCTAssertEqual(SpotMapLayout.gridStep(metre: 60), 1)
    XCTAssertEqual(SpotMapLayout.gridStep(metre: 20), 2)
    XCTAssertEqual(SpotMapLayout.gridStep(metre: 8), 5)
    XCTAssertEqual(SpotMapLayout.gridStep(metre: 3), 10)
  }

  func testDiagnosticsKeepOnlyTheirLatestLines() throws {
    let file = folder.appendingPathComponent("log/diagnostics.log")
    let log = SpotDiagnostics(file: file, limit: 400)
    for index in 0..<60 { log.note("event \(index)") }
    log.wait()
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    XCTAssertLessThanOrEqual(lines.joined(separator: "\n").utf8.count, 400)
    XCTAssertTrue(try XCTUnwrap(lines.last).hasSuffix("event 59"))
    XCTAssertFalse(lines.contains { $0.hasSuffix("event 0") })
    // Whole lines only, each with the time it was written.
    XCTAssertTrue(lines.allSatisfy { $0.contains(" event ") && $0.first?.isNumber == true })
  }

  func testTheFirstShotWaitsForTheCameraToSettleItsExposure() {
    // A camera that has just opened is still finding its exposure, which a spot then keeps.
    XCTAssertFalse(SpotRecorder.exposureSettled(after: 0.2, adjusting: false))
    XCTAssertTrue(SpotRecorder.exposureSettled(after: 0.6, adjusting: false))
    XCTAssertFalse(SpotRecorder.exposureSettled(after: 0.6, adjusting: true))
    // It does not wait for ever on a camera that never says it is done.
    XCTAssertTrue(SpotRecorder.exposureSettled(after: 1.6, adjusting: true))
  }
}
