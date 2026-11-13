import Foundation
import simd

/// One direction to capture while turning in place at a spot.
struct SpotTarget: Equatable {
  let ring: Int
  /// Radians, relative to the heading the spot started at; positive turns left (ARKit yaw).
  let yaw: Float
  /// Radians, positive upwards.
  let pitch: Float
}

enum SpotLayout {
  /// Six level shots on the 0.5× camera: one turn on the spot, never looking up or down. In
  /// portrait that lens sees about 87° across and 103° up and down, so neighbouring shots
  /// overlap by about 27° and the panorama reaches about 50° above and below level. The
  /// ceiling and floor beyond that are not photographed; the stitcher fills them softly.
  static let standard: [SpotTarget] = ring(0, count: 6, pitchDegrees: 0)

  private static func ring(_ ring: Int, count: Int, pitchDegrees: Float) -> [SpotTarget] {
    (0..<count).map { index in
      SpotTarget(
        ring: ring, yaw: Float(index) * 2 * .pi / Float(count), pitch: pitchDegrees * .pi / 180)
    }
  }
}

enum SpotTurnEvent: Equatable {
  /// Not lined up with the current dot.
  case none
  /// Lined up and holding; `holdProgress` is filling.
  case aligning
  /// The dot at this layout index was captured; save this frame as its slice.
  case capture(index: Int)
  /// The final dot was captured (it is `captured.last`): save this frame, then the spot is done.
  case complete
}

/// Which dot to line up next, and when a held dot counts as captured. Pure state, so the
/// capture screen and tests drive it with camera directions and timestamps.
struct SpotTurn {
  static let alignTolerance: Float = 4 * .pi / 180
  static let holdDuration = 0.5

  let layout: [SpotTarget]
  let startYaw: Float
  private(set) var captured: [Int] = []
  private(set) var holdProgress: Double = 0
  private(set) var current: SpotTarget?
  private var currentIndex: Int?
  private var holdStart: Double?
  /// Absolute yaw the camera last faced, for choosing the nearest next dot.
  private var heading: Float

  init(layout: [SpotTarget] = SpotLayout.standard, startYaw: Float) {
    self.layout = layout
    self.startYaw = startYaw
    heading = startYaw
    chooseNext()
  }

  var isComplete: Bool { captured.count == layout.count }
  var progress: Double { layout.isEmpty ? 1 : Double(captured.count) / Double(layout.count) }

  /// World direction (gravity-aligned, ARKit axes) of a target for this spot.
  func direction(of target: SpotTarget) -> SIMD3<Float> {
    let yaw = startYaw + target.yaw
    return SIMD3(-sin(yaw) * cos(target.pitch), sin(target.pitch), -cos(yaw) * cos(target.pitch))
  }

  mutating func update(forward: SIMD3<Float>, time: Double, steady: Bool) -> SpotTurnEvent {
    let forward = simd_normalize(forward)
    if abs(forward.y) < 0.95 { heading = atan2(-forward.x, -forward.z) }
    guard let index = currentIndex, let target = current else { return .none }
    let cosine = simd_clamp(simd_dot(forward, direction(of: target)), -1, 1)
    guard acos(cosine) < Self.alignTolerance, steady else {
      resetHold()
      return .none
    }
    let start = holdStart ?? time
    holdStart = start
    holdProgress = min(1, (time - start) / Self.holdDuration)
    guard time - start >= Self.holdDuration else { return .aligning }
    captured.append(index)
    resetHold()
    chooseNext()
    return isComplete ? .complete : .capture(index: index)
  }

  /// Removes the last captured dot and makes it the current one again.
  mutating func undo() -> Int? {
    guard let last = captured.popLast() else { return nil }
    resetHold()
    currentIndex = last
    current = layout[last]
    return last
  }

  private mutating func resetHold() {
    holdStart = nil
    holdProgress = 0
  }

  /// The nearest uncaptured dot by yaw in the lowest ring that still has one. Ties go to the
  /// lower index, so turning continues the way it started.
  private mutating func chooseNext() {
    let done = Set(captured)
    let remaining = layout.indices.filter { !done.contains($0) }
    guard let ring = remaining.map({ layout[$0].ring }).min() else {
      currentIndex = nil
      current = nil
      return
    }
    func distance(_ index: Int) -> Float {
      let difference = (startYaw + layout[index].yaw - heading).truncatingRemainder(
        dividingBy: 2 * .pi)
      let wrapped = abs(difference)
      return min(wrapped, 2 * .pi - wrapped)
    }
    let next = remaining.filter { layout[$0].ring == ring }.min { a, b in
      let (da, db) = (distance(a), distance(b))
      return abs(da - db) < 1e-4 ? a < b : da < db
    }!
    currentIndex = next
    current = layout[next]
  }
}
