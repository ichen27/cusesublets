import CoreImage
import XCTest

@testable import CuseSublets

final class CaptureStorageTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

  func testBudgetLowersQualitySoAFullTakeFitsTheUploadLimit() {
    // A busy room at full resolution: about 520 KB per view at quality 0.85.
    var budget = CaptureBudget()
    var lowest = budget.quality
    for _ in 0..<CapturePolicy.maximumViews {
      let image = Int(520_000 * budget.quality / 0.85)
      XCTAssertTrue(budget.fits(image: image, metadata: 26_000))
      budget.record(image: image, metadata: 26_000)
      lowest = min(lowest, budget.quality)
    }
    XCTAssertLessThanOrEqual(budget.archiveBytes, CaptureBudget.archiveLimit)
    // Quality drops early; the last few views may rise again to spend what is left.
    XCTAssertLessThan(lowest, 0.7)
  }

  func testBudgetKeepsQualityHighWhenImagesAreSmall() {
    var budget = CaptureBudget()
    for _ in 0..<20 { budget.record(image: 150_000, metadata: 10_000) }
    XCTAssertEqual(budget.quality, CaptureBudget.maximumQuality, accuracy: 0.001)
  }

  func testBudgetRefusesAViewThatWouldOverflowTheArchive() {
    var budget = CaptureBudget()
    var saved = 0
    while budget.fits(image: 1_500_000, metadata: 30_000) {
      budget.record(image: 1_500_000, metadata: 30_000)
      saved += 1
    }
    XCTAssertLessThan(saved, CapturePolicy.maximumViews)
    XCTAssertLessThanOrEqual(budget.archiveBytes, CaptureBudget.archiveLimit)
  }

  func testTrackedPointsAreThinnedAndRoundedToATenthOfAMillimetre() throws {
    let source = (0..<2500).map { SIMD3<Float>(Float($0) * 0.000_123_4, -1.234_567, 2) }
    let points = CaptureFrameRecord.points(source)
    XCTAssertEqual(points.count, CaptureFrameRecord.maximumPoints)
    XCTAssertEqual(points[1][1], -1.2346)
    let line = String(decoding: try JSONEncoder().encode(points), as: UTF8.self)
    XCTAssertFalse(line.contains("99999"), "points should not carry float noise: \(line.prefix(80))")
  }

  func testWriterSavesFullResolutionImagesAndOneRecordPerView() throws {
    let writer = CaptureWriter(folder: folder)
    let image = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
      .cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1440))
    for index in 0..<2 {
      let done = expectation(description: "saved \(index)")
      writer.save(image, record: record(index, path: "")) { outcome in
        if case .saved(let count) = outcome { XCTAssertEqual(count, index + 1) } else {
          XCTFail("unexpected \(outcome)")
        }
        done.fulfill()
      }
      XCTAssertTrue(writer.busy)
      wait(for: [done], timeout: 10)
      XCTAssertFalse(writer.busy)
    }
    let saved = try XCTUnwrap(
      CGImageSourceCreateWithURL(folder.appendingPathComponent("images/00001.jpg") as CFURL, nil))
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(saved, 0, nil) as? [CFString: Any])
    XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1920)
    let frames = try PhotoRecorder.savedFrames(in: folder)
    XCTAssertEqual(frames.map(\.filePath), ["images/00000.jpg", "images/00001.jpg"])
  }

  func testRecoveryKeepsTheCompleteViewsOfAnInterruptedTake() throws {
    // 31 complete views, then a view whose record was cut off mid-write.
    var lines = Data()
    for index in 0..<32 {
      let path = String(format: "images/%05d.jpg", index)
      try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: folder.appendingPathComponent(path))
      lines += try JSONEncoder().encode(record(index, path: path)) + Data("\n".utf8)
    }
    lines.removeLast(40)
    try lines.write(to: folder.appendingPathComponent(PhotoRecorder.recordsName))
    XCTAssertEqual(try PhotoRecorder.savedFrames(in: folder).count, 31)
    let archive = try PhotoRecorder.package(folder: folder)
    XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    let manifest = try JSONDecoder().decode(
      CaptureManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    XCTAssertEqual(manifest.frames.count, 31)
    XCTAssertEqual(manifest.frames.last?.filePath, "images/00030.jpg")
  }

  func testRecoveryStopsAtAViewWhoseImageIsMissing() throws {
    var lines = Data()
    for index in 0..<3 {
      let path = String(format: "images/%05d.jpg", index)
      if index != 1 {
        try Data([0xFF, 0xD8]).write(to: folder.appendingPathComponent(path))
      }
      lines += try JSONEncoder().encode(record(index, path: path)) + Data("\n".utf8)
    }
    try lines.write(to: folder.appendingPathComponent(PhotoRecorder.recordsName))
    // Processing requires consecutive image names, so a gap ends the usable take.
    XCTAssertEqual(try PhotoRecorder.savedFrames(in: folder).map(\.filePath), ["images/00000.jpg"])
  }

  private func record(_ index: Int, path: String) -> CaptureFrameRecord {
    CaptureFrameRecord(
      filePath: path, timestamp: Double(index) + 1, width: 1920, height: 1440, fx: 1450,
      fy: 1450, cx: 960, cy: 720,
      transformMatrix: [[1, 0, 0, Double(index) * 0.1], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]],
      points: CaptureFrameRecord.points([SIMD3(0, 0, -2), SIMD3(1, 0, -2)]))
  }
}
