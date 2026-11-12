import CryptoKit
import Foundation

/// One finished spot: the slices to stitch and where the person stood.
struct SpotRecord: Codable, Equatable {
  var spot: Int
  /// `file_path`s of this spot's slice images, in capture order.
  var slices: [String]
  /// Mean camera position during the turn, ARKit world metres.
  var position: [Double]
  var floorY: Double
  /// Heading the turn started at, radians (ARKit yaw).
  var startYaw: Double
  /// The locked exposure for every slice of this spot.
  var exposureDuration: Double
  var iso: Double
  /// `"ultrawide"` when the slices came from the 0.5× camera with motion-sensor rotations.
  var lens: String? = nil
  /// Degrees between ARKit's and the motion sensors' idea of "up" when the spot started.
  var gravityMismatch: Double? = nil

  enum CodingKeys: String, CodingKey {
    case floorY = "floor_y"
    case startYaw = "start_yaw"
    case exposureDuration = "exposure_duration"
    case gravityMismatch = "gravity_mismatch"
    case spot, slices, position, iso, lens
  }
}

/// On-disk layout of a spot take. Frames use the walk-around take's `frames.jsonl` and
/// `images/` (tagged by role); finished spots are appended to `spots.jsonl` only after every
/// slice is written, so recovery never reports a half-turned spot.
enum SpotTake {
  static let maximumSpots = 8
  static let maximumWalkFrames = 90
  /// Below the Workers request-body limit.
  static let archiveLimit = 96 * 1024 * 1024
  static let sliceWidth: CGFloat = 1920
  static let spotsName = "spots.jsonl"
  static let archiveName = "spots.roomcapture"
  static var maximumViews: Int { maximumSpots * SpotLayout.standard.count + maximumWalkFrames }

  /// Same key as walk-around takes, but its own root, so the two never collide.
  static func folder(owner: String, listing: String) -> URL {
    let key = SHA256.hash(data: Data((owner + "/" + listing).utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("spot-captures", isDirectory: true).appendingPathComponent(
        key, isDirectory: true)
  }

  private struct Tombstone: Codable {
    var spot: Int
    var deleted: Bool
  }

  static func appendSpot(_ spot: SpotRecord, to folder: URL) throws {
    try append(JSONEncoder().encode(spot), to: folder)
  }

  static func deleteSpot(_ spot: Int, in folder: URL) throws {
    try append(JSONEncoder().encode(Tombstone(spot: spot, deleted: true)), to: folder)
  }

  /// Finished, undeleted spots whose every slice is among the complete frames, by number.
  static func savedSpots(in folder: URL, frames: [CaptureFrameRecord]) -> [SpotRecord] {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent(spotsName)) else {
      return []
    }
    var spots = [Int: SpotRecord]()
    for line in data.split(separator: UInt8(ascii: "\n")) {
      if let tombstone = try? JSONDecoder().decode(Tombstone.self, from: Data(line)),
        tombstone.deleted
      {
        spots[tombstone.spot] = nil
      } else if let spot = try? JSONDecoder().decode(SpotRecord.self, from: Data(line)) {
        spots[spot.spot] = spot
      }
    }
    let complete = Set(frames.map(\.filePath))
    return spots.values.filter { !$0.slices.isEmpty && $0.slices.allSatisfy(complete.contains) }
      .sorted { $0.spot < $1.spot }
  }

  /// Removes a take that ended without a finished spot, so it neither blocks the next capture
  /// nor leaves room photos on the phone. Returns whether it was removed.
  @discardableResult
  static func discardIfEmpty(folder: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: folder.path) else { return false }
    let frames = (try? PhotoRecorder.savedFrames(in: folder)) ?? []
    guard savedSpots(in: folder, frames: frames).isEmpty else { return false }
    try FileManager.default.removeItem(at: folder)
    return true
  }

  /// Writes manifest version 2 and the upload archive. Frames of unfinished or deleted spots
  /// stay in it: they cannot reach a panorama, but still help the mesh.
  static func package(folder: URL) throws -> URL {
    let frames = try PhotoRecorder.savedFrames(in: folder)
    let spots = savedSpots(in: folder, frames: frames)
    guard !spots.isEmpty else {
      throw CaptureFailure.message("Capture at least one spot before generating.")
    }
    try JSONEncoder().encode(CaptureManifest(spots: spots, frames: frames)).write(
      to: folder.appendingPathComponent("manifest.json"),
      options: [.atomic, .completeFileProtection])
    let entries =
      [("manifest.json", folder.appendingPathComponent("manifest.json"))]
      + frames.map { ($0.filePath, folder.appendingPathComponent($0.filePath)) }
    let target = folder.appendingPathComponent(archiveName)
    try CaptureArchive.write(
      entries: entries, to: target, limit: archiveLimit,
      limitMessage: "Capture exceeds 96 MB. Remove a spot and try again.")
    return target
  }

  private static func append(_ line: Data, to folder: URL) throws {
    let url = folder.appendingPathComponent(spotsName)
    if !FileManager.default.fileExists(atPath: url.path) {
      guard
        FileManager.default.createFile(
          atPath: url.path, contents: nil,
          attributes: [.protectionKey: FileProtectionType.complete])
      else { throw CaptureFailure.message("The spot could not be saved.") }
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line + Data("\n".utf8))
    try handle.synchronize()
  }
}
