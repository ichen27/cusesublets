import XCTest
import simd

@testable import CuseSublets

final class CaptureStreamTests: XCTestCase {
  private var take: URL!

  override func setUpWithError() throws {
    take = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try StreamRecorder(folder: take).prepare()
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: take) }

  func testEveryReasonPaintsOnlyWhenTheFrameIsSharpAndTracked() {
    let usable = Set(CaptureReason.allCases.filter(\.usable))
    XCTAssertEqual(usable, [.saved, .tooSoon, .noNewViewpoint, .turnLimit, .writerBusy])
    XCTAssertEqual(CaptureDecision(reason: .blurred).hint, .holdSteadier)
    XCTAssertEqual(CaptureDecision(reason: .turnLimit).hint, .stepSideways)
    XCTAssertNil(CaptureDecision(reason: .noNewViewpoint).hint)
    XCTAssertTrue(CaptureDecision(reason: .saved).save)
  }

  func testPolicyReportsTheMotionItJudged() throws {
    var policy = CapturePolicy()
    let sample = { (time: Double, yaw: Float) in
      CaptureSample(
        time: time, position: .zero, forward: SIMD3(-sin(yaw), 0, -cos(yaw)), tracking: true,
        exposure: 1.0 / 60, focalLength: 1450, sceneDepth: 2, featureCount: 200)
    }
    _ = policy.evaluate(sample(1, 0))
    XCTAssertNil(policy.motion, "one frame cannot measure motion")
    let decision = policy.evaluate(sample(1.1, 0.03))
    let motion = try XCTUnwrap(policy.motion)
    XCTAssertEqual(motion.turnRate, 0.3, accuracy: 0.001)
    XCTAssertEqual(motion.blur, 0.3 / 60 * 1450, accuracy: 0.01)
    XCTAssertEqual(decision.reason, .blurred)
    _ = policy.evaluate(
      CaptureSample(
        time: 1.2, position: .zero, forward: SIMD3(0, 0, -1), tracking: false, exposure: 1.0 / 60,
        focalLength: 1450, sceneDepth: 2, featureCount: 200))
    XCTAssertNil(policy.motion)
  }

  func testPackagingKeepsCompleteFramesAndMarksAMissingSummary() throws {
    let folder = take.appendingPathComponent(StreamRecorder.directory)
    var lines = Data()
    for index in 0..<3 {
      let path = String(format: "frames/%05d.jpg", index)
      try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: folder.appendingPathComponent(path))
      lines += try JSONEncoder().encode(record(index, path: path)) + Data("\n".utf8)
    }
    lines.removeLast(30)
    try lines.write(to: folder.appendingPathComponent(StreamRecorder.recordsName))
    XCTAssertTrue(StreamRecorder.exists(in: take))
    XCTAssertEqual(try StreamRecorder.savedFrames(in: take).count, 2)
    let archive = try StreamRecorder.package(take: take)
    XCTAssertEqual(archive.lastPathComponent, "room.roomstream")
    XCTAssertEqual(
      try tarNames(archive),
      ["summary.json", "stream.jsonl", "frames/00000.jpg", "frames/00001.jpg"])
    let summary = try JSONDecoder().decode(
      StreamSummary.self,
      from: Data(contentsOf: folder.appendingPathComponent(StreamRecorder.summaryName)))
    XCTAssertFalse(summary.complete)
    XCTAssertEqual(summary.recordedFrames, 2)
    XCTAssertEqual(summary.rules["maximum_blur_px"], 4)
  }

  func testRecordsUseTheProcessingConventionsAndNamedReasons() throws {
    let line = String(
      decoding: try JSONEncoder().encode(record(0, path: "frames/00000.jpg")), as: UTF8.self)
    XCTAssertTrue(line.contains("\"transform_matrix\""))
    XCTAssertTrue(line.contains("\"reason\":\"blurred\""))
    XCTAssertTrue(line.contains("\"turn_rate\""))
  }

  func testStreamArchivesAcceptOnlyStreamFiles() {
    XCTAssertTrue(StreamRecorder.isStreamName("frames/00012.jpg"))
    XCTAssertFalse(StreamRecorder.isStreamName("images/00012.jpg"))
    XCTAssertFalse(StreamRecorder.isStreamName("manifest.json"))
    XCTAssertFalse(CaptureArchive.isCaptureName("frames/00012.jpg"))
  }

  func testNoStreamWithoutFrames() {
    XCTAssertFalse(StreamRecorder.exists(in: take))
    XCTAssertThrowsError(try StreamRecorder.package(take: take))
  }

  private func record(_ index: Int, path: String) -> StreamFrameRecord {
    StreamFrameRecord(
      filePath: path, timestamp: Double(index) * 0.2, width: 640, height: 480, fx: 480, fy: 480,
      cx: 320, cy: 240,
      transformMatrix: [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]],
      tracking: "normal", exposure: 1.0 / 60, exposureOffset: 0, ambientIntensity: 900,
      featureCount: 120, points: [[0, 0, -2]], reason: .blurred, hint: nil, speed: 0.1,
      turnRate: 0.4, depth: 2, blur: 9.6, views: index)
  }

  private func tarNames(_ url: URL) throws -> [String] {
    let data = try Data(contentsOf: url)
    var names = [String]()
    var offset = 0
    while offset + 512 <= data.count {
      let header = data[offset..<(offset + 512)]
      guard header.contains(where: { $0 != 0 }) else { break }
      names.append(String(decoding: header.prefix(100).prefix { $0 != 0 }, as: UTF8.self))
      let sizeText = String(
        decoding: header.dropFirst(124).prefix(11), as: UTF8.self)
      let size = Int(sizeText, radix: 8) ?? 0
      offset += 512 + size + (512 - size % 512) % 512
    }
    return names
  }
}
