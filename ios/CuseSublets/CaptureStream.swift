import ARKit
import CoreImage
import Foundation

/// One camera frame of a development stream recording. Unlike the views of a take, the stream
/// keeps frames the capture rules skipped, with the reason and the measured motion, so the rules
/// and live reconstruction can be tested offline.
struct StreamFrameRecord: Codable, Equatable {
  var filePath: String
  var timestamp: Double
  var width: Int
  var height: Int
  var fx: Double
  var fy: Double
  var cx: Double
  var cy: Double
  /// ARKit camera-to-world transform, row-major.
  var transformMatrix: [[Double]]
  /// "normal", "limited" or "notAvailable".
  var tracking: String
  /// Shutter time in seconds.
  var exposure: Double
  var exposureOffset: Double
  var ambientIntensity: Double?
  var featureCount: Int
  var points: [[Double]]
  var reason: CaptureReason
  /// Text shown over the camera at this moment, if any.
  var hint: String?
  var speed: Double?
  var turnRate: Double?
  var depth: Double?
  var blur: Double?
  /// Views saved to the take so far.
  var views: Int

  enum CodingKeys: String, CodingKey {
    case filePath = "file_path"
    case transformMatrix = "transform_matrix"
    case exposureOffset = "exposure_offset"
    case ambientIntensity = "ambient_intensity"
    case featureCount = "feature_count"
    case turnRate = "turn_rate"
    case timestamp, width, height, fx, fy, cx, cy, tracking, exposure, points, reason, hint
    case speed, depth, blur, views
  }
}

/// Totals for a whole stream, including frames between recorded ones.
struct StreamSummary: Codable {
  var schemaVersion = 1
  var device: String
  var system: String
  var cameraWidth: Int
  var cameraHeight: Int
  var duration: Double
  var recordedFrames: Int
  /// Frames due for recording that were skipped because the previous one was still being written.
  var droppedFrames: Int
  /// Seconds of camera time that ended with each policy reason, over every camera frame.
  var reasonSeconds: [String: Double]
  var rules: [String: Double]
  /// False when the app stopped before the summary could be written at the end of capture.
  var complete: Bool

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case cameraWidth = "camera_width"
    case cameraHeight = "camera_height"
    case recordedFrames = "recorded_frames"
    case droppedFrames = "dropped_frames"
    case reasonSeconds = "reason_seconds"
    case device, system, duration, rules, complete
  }

  static var rules: [String: Double] {
    [
      "maximum_blur_px": Double(CapturePolicy.maximumBlur),
      "minimum_features": Double(CapturePolicy.minimumFeatures),
      "minimum_interval_s": CapturePolicy.minimumInterval,
      "maximum_speed_mps": Double(CapturePolicy.maximumSpeed),
      "maximum_turn_rate_rps": Double(CapturePolicy.maximumTurnRate),
      "parallax": Double(CapturePolicy.parallax),
      "turn_angle_rad": Double(CapturePolicy.turnAngle),
      "maximum_turns_in_place": Double(CapturePolicy.maximumTurnsInPlace),
    ]
  }
}

/// Records a small camera frame every 0.2 s during development captures. The frame is shrunk on
/// the camera thread, which frees ARKit's buffer at once; JPEG encoding and writing run on a
/// background queue, and a frame due while the previous one is still being written is dropped
/// rather than delaying the camera.
final class StreamRecorder {
  static let directory = "stream"
  static let recordsName = "stream.jsonl"
  static let summaryName = "summary.json"
  static let archiveName = "room.roomstream"
  static let interval = 0.2
  static let width = 640
  static let height = 480
  static let maximumPoints = 300
  /// Recording stops, while capture continues, once the stream reaches this size.
  static let maximumBytes = 200 * 1024 * 1024

  let folder: URL
  // Main thread only.
  private var busy = false
  private var lastRecorded = -Double.infinity
  private var lastFrame: Double?
  private var reasonSeconds = [String: Double]()
  private var dropped = 0
  private var stopped = false
  private var cameraSize = CGSize.zero
  // Writer queue only.
  private var recorded = 0
  private var bytes = 0
  private let queue = DispatchQueue(label: "com.ichen27.cusesublets.stream", qos: .utility)
  private let context = CIContext()
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  init(folder: URL) {
    self.folder = folder.appendingPathComponent(Self.directory, isDirectory: true)
  }

  func prepare() throws {
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent("frames"), withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.complete])
  }

  /// Call on the main thread for every camera frame, after the policy has decided.
  func observe(
    _ frame: ARFrame, elapsed: Double, decision: CaptureDecision, motion: CaptureMotion?,
    hint: CaptureHint?, views: Int
  ) {
    if let lastFrame, elapsed > lastFrame {
      reasonSeconds[decision.reason.rawValue, default: 0] += elapsed - lastFrame
    }
    lastFrame = elapsed
    cameraSize = CGSize(
      width: CVPixelBufferGetWidth(frame.capturedImage),
      height: CVPixelBufferGetHeight(frame.capturedImage))
    guard !stopped, elapsed - lastRecorded >= Self.interval else { return }
    lastRecorded = elapsed
    guard !busy else {
      dropped += 1
      return
    }
    guard let small = shrink(frame.capturedImage) else { return }
    let sx = Double(Self.width) / Double(cameraSize.width)
    let sy = Double(Self.height) / Double(cameraSize.height)
    let k = frame.camera.intrinsics
    let pose = frame.camera.transform
    var tracking = "notAvailable"
    switch frame.camera.trackingState {
    case .normal: tracking = "normal"
    case .limited: tracking = "limited"
    case .notAvailable: break
    }
    let record = StreamFrameRecord(
      filePath: "", timestamp: elapsed, width: Self.width, height: Self.height,
      fx: Double(k[0][0]) * sx, fy: Double(k[1][1]) * sy, cx: Double(k[2][0]) * sx,
      cy: Double(k[2][1]) * sy,
      transformMatrix: (0..<4).map { row in (0..<4).map { column in Double(pose[column][row]) } },
      tracking: tracking, exposure: frame.camera.exposureDuration,
      exposureOffset: Double(frame.camera.exposureOffset),
      ambientIntensity: frame.lightEstimate.map { Double($0.ambientIntensity) },
      featureCount: frame.rawFeaturePoints?.points.count ?? 0,
      points: CaptureFrameRecord.points(
        frame.rawFeaturePoints?.points ?? [], limit: Self.maximumPoints),
      reason: decision.reason, hint: hint?.message,
      speed: motion.map { Double($0.speed) }, turnRate: motion.map { Double($0.turnRate) },
      depth: motion.map { Double($0.depth) }, blur: motion.map { Double($0.blur) }, views: views)
    busy = true
    queue.async {
      let full = !self.write(small, record)
      DispatchQueue.main.async {
        self.busy = false
        if full { self.stopped = true }
      }
    }
  }

  /// Writes the summary after any frame still being written. Call on the main thread.
  func finish(duration: Double) {
    stopped = true
    let summary = summary(duration: duration, complete: true)
    queue.async {
      var summary = summary
      summary.recordedFrames = self.recorded
      try? Self.writeSummary(summary, in: self.folder)
    }
  }

  private func summary(duration: Double, complete: Bool) -> StreamSummary {
    var system = utsname()
    uname(&system)
    let machine = withUnsafeBytes(of: &system.machine) {
      String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
    }
    return StreamSummary(
      device: machine, system: "iOS \(UIDevice.current.systemVersion)",
      cameraWidth: Int(cameraSize.width), cameraHeight: Int(cameraSize.height),
      duration: duration, recordedFrames: 0, droppedFrames: dropped,
      reasonSeconds: reasonSeconds, rules: StreamSummary.rules, complete: complete)
  }

  private func shrink(_ image: CVPixelBuffer) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard
      CVPixelBufferCreate(
        nil, Self.width, Self.height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        == kCVReturnSuccess, let buffer
    else { return nil }
    let source = CIImage(cvPixelBuffer: image)
    let scaled = source.transformed(
      by: CGAffineTransform(
        scaleX: CGFloat(Self.width) / source.extent.width,
        y: CGFloat(Self.height) / source.extent.height))
    context.render(scaled, to: buffer)
    return buffer
  }

  /// Returns false once the stream is full.
  private func write(_ image: CVPixelBuffer, _ record: StreamFrameRecord) -> Bool {
    let name = String(format: "frames/%05d.jpg", recorded)
    var record = record
    record.filePath = name
    let option = CIImageRepresentationOption(
      rawValue: kCGImageDestinationLossyCompressionQuality as String)
    guard
      let jpeg = context.jpegRepresentation(
        of: CIImage(cvPixelBuffer: image), colorSpace: colorSpace, options: [option: 0.7]),
      let encoded = try? JSONEncoder().encode(record)
    else { return true }
    let line = encoded + Data("\n".utf8)
    guard bytes + jpeg.count + line.count <= Self.maximumBytes else { return false }
    do {
      try jpeg.write(
        to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
      try Self.append(line, to: folder.appendingPathComponent(Self.recordsName))
    } catch { return true }
    bytes += jpeg.count + line.count
    recorded += 1
    return true
  }

  private static func append(_ line: Data, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
      guard
        FileManager.default.createFile(
          atPath: url.path, contents: nil,
          attributes: [.protectionKey: FileProtectionType.complete])
      else { throw CaptureFailure.message("The stream could not be saved.") }
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }

  private static func writeSummary(_ summary: StreamSummary, in folder: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(summary).write(
      to: folder.appendingPathComponent(summaryName), options: [.atomic, .completeFileProtection])
  }

  /// Whether a take folder holds a stream recording with at least one frame.
  static func exists(in take: URL) -> Bool {
    FileManager.default.fileExists(
      atPath: take.appendingPathComponent(directory).appendingPathComponent(recordsName).path)
  }

  /// The complete frames of a stream, in order, stopping at a cut-off record or missing image.
  static func savedFrames(in take: URL) throws -> [StreamFrameRecord] {
    let folder = take.appendingPathComponent(directory)
    var frames = [StreamFrameRecord]()
    let data = try Data(contentsOf: folder.appendingPathComponent(recordsName))
    for line in data.split(separator: UInt8(ascii: "\n")) {
      let expected = String(format: "frames/%05d.jpg", frames.count)
      guard let frame = try? JSONDecoder().decode(StreamFrameRecord.self, from: Data(line)),
        frame.filePath == expected,
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(expected).path)
      else { break }
      frames.append(frame)
    }
    return frames
  }

  static func isStreamName(_ name: String) -> Bool {
    name == recordsName || name == summaryName
      || name.range(of: "^frames/[0-9]{5}\\.jpg$", options: .regularExpression) != nil
  }

  /// Packages the stream as an uncompressed USTAR archive next to the take. A stream cut short
  /// before its summary was written gets one marked incomplete.
  static func package(take: URL) throws -> URL {
    let folder = take.appendingPathComponent(directory)
    let frames = try savedFrames(in: take)
    guard !frames.isEmpty else {
      throw CaptureFailure.message("This take has no camera stream recording.")
    }
    let records = folder.appendingPathComponent("packaged.jsonl")
    let encoder = JSONEncoder()
    var lines = Data()
    for frame in frames { lines += try encoder.encode(frame) + Data("\n".utf8) }
    try lines.write(to: records, options: [.atomic, .completeFileProtection])
    let summary = folder.appendingPathComponent(summaryName)
    if !FileManager.default.fileExists(atPath: summary.path) {
      try writeSummary(
        StreamSummary(
          device: "", system: "", cameraWidth: 0, cameraHeight: 0,
          duration: frames.last?.timestamp ?? 0, recordedFrames: frames.count, droppedFrames: 0,
          reasonSeconds: [:], rules: StreamSummary.rules, complete: false), in: folder)
    }
    let entries =
      [(summaryName, summary), (recordsName, records)]
      + frames.map { ($0.filePath, folder.appendingPathComponent($0.filePath)) }
    let target = take.appendingPathComponent(archiveName)
    try CaptureArchive.write(
      entries: entries, to: target, allowed: isStreamName, limit: maximumBytes + 1024 * 1024,
      limitMessage: "The camera stream is too large to export.")
    return target
  }
}
