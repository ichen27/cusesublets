import Foundation
import simd

/// The room-coverage percentage: how much of the floor seen so far a captured spot can see
/// within arm's-reach-plus distance. Guidance, not a measurement.
enum FloorCoverage {
  static let reach: Float = 1.5

  /// Share of floor cells (excluding floor under obstacles) visible from some spot within
  /// `reach`, with obstacle cells blocking the line of sight. Spots are (x, z) in metres.
  static func fraction(cells: [TopDownCell], spots: [SIMD2<Float>]) -> Double {
    let open = cells.filter { $0.floor && !$0.obstacle }
    guard !open.isEmpty, !spots.isEmpty else { return 0 }
    let blocked = Set(cells.filter(\.obstacle).map { SIMD2($0.x, $0.z) })
    let size = CoverageMap.voxelSize
    let origins = spots.map { SIMD2<Int32>(Int32(floor($0.x / size)), Int32(floor($0.y / size))) }
    let covered = open.filter { cell in
      let target = SIMD2(cell.x, cell.z)
      let point = (SIMD2<Float>(Float(cell.x), Float(cell.z)) + 0.5) * size
      return zip(spots, origins).contains { spot, origin in
        simd_distance(spot, point) <= reach && clear(from: origin, to: target, blocked: blocked)
      }
    }
    return Double(covered.count) / Double(open.count)
  }

  /// Bresenham line between grid cells; the start (where the person stood) never blocks.
  private static func clear(
    from start: SIMD2<Int32>, to end: SIMD2<Int32>, blocked: Set<SIMD2<Int32>>
  ) -> Bool {
    var (x, z) = (start.x, start.y)
    let dx = abs(end.x - x)
    let dz = -abs(end.y - z)
    let sx: Int32 = x < end.x ? 1 : -1
    let sz: Int32 = z < end.y ? 1 : -1
    var error = dx + dz
    while x != end.x || z != end.y {
      let twice = 2 * error
      if twice >= dz {
        error += dz
        x += sx
      }
      if twice <= dx {
        error += dx
        z += sz
      }
      if blocked.contains(SIMD2(x, z)) { return false }
    }
    return true
  }

  /// The floor height: the lowest horizontal ARKit plane, else the 5th percentile of the map's
  /// surface heights (robust to a few stray points below the floor), else unknown.
  static func estimateFloorY(planes: [Float], cells: [SIMD3<Float>]) -> Float? {
    if let lowest = planes.min() { return lowest }
    guard !cells.isEmpty else { return nil }
    let heights = cells.map(\.y).sorted()
    return heights[min(heights.count - 1, Int(Double(heights.count) * 0.05))]
  }
}
