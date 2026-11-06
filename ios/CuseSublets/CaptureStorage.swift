import CoreImage
import Foundation
import simd

/// One saved view as the processing engine reads it from `manifest.json`.
struct CaptureFrameRecord: Codable, Equatable {
  /// The engine accepts at most 1,000 tracked points per view.
  static let maximumPoints = 1000

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
  var tracking = "normal"
  var points: [[Double]]

  enum CodingKeys: String, CodingKey {
    case filePath = "file_path"
    case transformMatrix = "transform_matrix"
    case timestamp, width, height, fx, fy, cx, cy, tracking, points
  }

  /// Evenly thins tracked points to the engine's limit and rounds them to 0.1 mm, which keeps a
  /// full take's manifest to a few megabytes.
  static func points(_ source: [SIMD3<Float>]) -> [[Double]] {
    let count = min(source.count, maximumPoints)
    return (0..<count).map { index in
      let point = source[index * source.count / count]
      return [rounded(point.x), rounded(point.y), rounded(point.z)]
    }
  }
  private static func rounded(_ value: Float) -> Double { (Double(value) * 10_000).rounded() / 10_000 }
}

struct CaptureManifest: Codable {
  var schemaVersion = 1
  var source = "arkit"
  var coordinateSystem = "arkit-camera-to-world"
  var capability = "camera"
  var frames: [CaptureFrameRecord]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case coordinateSystem = "coordinate_system"
    case source, capability, frames
  }
}

/// Keeps a take inside the 64 MB upload limit. Each view gets an equal share of what is left,
/// after reserving manifest space for every view still to come, and JPEG quality follows the
/// share: high for simple rooms, lower for busy ones, rather than refusing the take at the end.
struct CaptureBudget {
  static let archiveLimit = 64 * 1024 * 1024
  /// Manifest bytes one view can need: 1,000 rounded points plus calibration.
  static let metadataReserve = 32 * 1024
  static let manifestEnvelope = 512
  static let maximumQuality = 0.85
  static let minimumQuality = 0.5

  let maximumViews: Int
  private(set) var quality = maximumQuality
  private(set) var views = 0
  private var imageBytes = 0
  private var metadataBytes = 0

  init(maximumViews: Int = CapturePolicy.maximumViews) { self.maximumViews = maximumViews }

  /// Bytes one entry occupies in the uncompressed USTAR archive.
  static func entrySize(_ bytes: Int) -> Int { 512 + bytes + (512 - bytes % 512) % 512 }

  var archiveBytes: Int {
    1024 + imageBytes + Self.entrySize(Self.manifestEnvelope + metadataBytes)
  }

  /// Average image size the remaining views can afford.
  var target: Int {
    let remaining = max(1, maximumViews - views)
    let free = Self.archiveLimit - archiveBytes - remaining * (Self.metadataReserve + 1024)
    return max(0, free / remaining)
  }

  /// Whether a view fits while leaving manifest space for every view that could follow it.
  func fits(image: Int, metadata: Int) -> Bool {
    guard views < maximumViews else { return false }
    let future = (maximumViews - views - 1) * Self.metadataReserve
    let manifest = Self.manifestEnvelope + metadataBytes + metadata + future
    return 1024 + imageBytes + Self.entrySize(image) + Self.entrySize(manifest)
      <= Self.archiveLimit
  }

  mutating func record(image: Int, metadata: Int) {
    let ratio = Double(image) / Double(max(target, 1))
    if ratio > 1.3 {
      quality -= 0.1
    } else if ratio > 1 {
      quality -= 0.05
    } else if ratio < 0.75 {
      quality += 0.05
    }
    quality = min(max(quality, Self.minimumQuality), Self.maximumQuality)
    views += 1
    imageBytes += Self.entrySize(image)
    metadataBytes += metadata
  }
}

/// Encodes and writes views on a background queue so the camera feed never waits on JPEG
/// encoding or disk. Each view's image is written before its record, so the records file always
/// describes complete images even if the app is killed mid-write.
final class CaptureWriter {
  enum Outcome {
    case saved(count: Int)
    /// The view would push the take past the upload limit; nothing was written.
    case full
    case failed(String)
  }

  let folder: URL
  /// Main thread only. True while a view is being written.
  private(set) var busy = false
  private let queue = DispatchQueue(label: "com.ichen27.cusesublets.capture-writer", qos: .userInitiated)
  private let context = CIContext()
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
  // Writer queue only.
  private var budget = CaptureBudget()
  private var count = 0

  init(folder: URL) { self.folder = folder }

  /// Call on the main thread. The image keeps the camera buffer alive until it is encoded, so
  /// callers save one view at a time (check `busy`).
  func save(
    _ image: CIImage, record: CaptureFrameRecord, completion: @escaping (Outcome) -> Void
  ) {
    busy = true
    queue.async {
      let outcome = self.write(image, record)
      DispatchQueue.main.async {
        self.busy = false
        completion(outcome)
      }
    }
  }

  /// Runs `work` on the writer queue after every pending view, with the number saved.
  func afterPendingWrites(_ work: @escaping (Int) -> Void) {
    queue.async { work(self.count) }
  }

  private func write(_ image: CIImage, _ record: CaptureFrameRecord) -> Outcome {
    let name = String(format: "images/%05d.jpg", count)
    var record = record
    record.filePath = name
    let option = CIImageRepresentationOption(
      rawValue: kCGImageDestinationLossyCompressionQuality as String)
    guard
      let jpeg = context.jpegRepresentation(
        of: image, colorSpace: colorSpace, options: [option: budget.quality]),
      let encoded = try? JSONEncoder().encode(record)
    else { return .failed("Camera frame could not be saved. Start a new take.") }
    let line = encoded + Data("\n".utf8)
    guard budget.fits(image: jpeg.count, metadata: line.count) else { return .full }
    do {
      try jpeg.write(
        to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
      try append(line)
    } catch { return .failed(error.localizedDescription) }
    budget.record(image: jpeg.count, metadata: line.count)
    count += 1
    return .saved(count: count)
  }

  private func append(_ line: Data) throws {
    let url = folder.appendingPathComponent(PhotoRecorder.recordsName)
    if !FileManager.default.fileExists(atPath: url.path) {
      guard
        FileManager.default.createFile(
          atPath: url.path, contents: nil,
          attributes: [.protectionKey: FileProtectionType.complete])
      else { throw CaptureFailure.message("The take could not be saved. Start a new take.") }
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }
}
