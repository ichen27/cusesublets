import Foundation
import simd

/// Pinhole camera for one saved view, with intrinsics in depth-map pixels and ARKit's
/// camera-to-world transform (camera looks along -z, +y up; image v grows downward).
struct CoverageCamera {
  var fx: Float
  var fy: Float
  var cx: Float
  var cy: Float
  var transform: simd_float4x4
  var position: SIMD3<Float> {
    SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
  }
  /// Depth-map pixel and distance along the view axis for a world point in front of the camera.
  func project(_ world: SIMD3<Float>) -> (u: Float, v: Float, depth: Float)? {
    let c = transform.inverse * SIMD4(world, 1)
    let depth = -c.z
    guard depth > 0.05 else { return nil }
    return (fx * c.x / depth + cx, cy - fy * c.y / depth, depth)
  }
  func unproject(u: Float, v: Float, depth: Float) -> SIMD3<Float> {
    let c = transform * SIMD4((u - cx) * depth / fx, (cy - v) * depth / fy, -depth, 1)
    return SIMD3(c.x, c.y, c.z)
  }
}

/// Model output: relative inverse depth (larger is nearer) in row-major order.
struct RelativeDepthMap {
  let width: Int
  let height: Int
  let values: [Float]
  func value(_ x: Int, _ y: Int) -> Float { values[y * width + x] }
  func sample(u: Float, v: Float) -> Float? {
    let x = Int(u.rounded())
    let y = Int(v.rounded())
    guard x >= 0, y >= 0, x < width, y < height else { return nil }
    return value(x, y)
  }
}

/// Converts the model's relative output to metres. Monocular depth is only defined up to an
/// affine transform of inverse depth, so fit `1/z ≈ a·p + b` to ARKit's tracked points.
enum DepthScale {
  static let minimumPoints = 12

  static func fit(_ pairs: [(prediction: Float, depth: Float)]) -> (a: Float, b: Float)? {
    let usable = pairs.filter { $0.depth > 0.1 && $0.depth < 10 && $0.prediction.isFinite }
    guard var line = solve(usable) else { return nil }
    // One trimming pass removes tracked points the model placed on the wrong surface.
    let errors = usable.map { relativeError($0, line) }
    let limit = max(0.05, 2 * median(errors))
    let kept = zip(usable, errors).filter { $0.1 <= limit }.map(\.0)
    guard let refit = solve(kept) else { return nil }
    line = refit
    guard line.a > 0, median(kept.map { relativeError($0, line) }) < 0.25 else { return nil }
    return line
  }
  private static func solve(_ pairs: [(prediction: Float, depth: Float)]) -> (a: Float, b: Float)? {
    guard pairs.count >= minimumPoints else { return nil }
    let n = Float(pairs.count)
    var sx: Float = 0
    var sy: Float = 0
    var sxx: Float = 0
    var sxy: Float = 0
    for (p, z) in pairs {
      sx += p
      sy += 1 / z
      sxx += p * p
      sxy += p / z
    }
    let det = n * sxx - sx * sx
    guard abs(det) > 1e-6 else { return nil }
    let a = (n * sxy - sx * sy) / det
    return (a, (sy - a * sx) / n)
  }
  private static func relativeError(
    _ pair: (prediction: Float, depth: Float), _ line: (a: Float, b: Float)
  ) -> Float {
    let inverse = line.a * pair.prediction + line.b
    guard inverse > 0 else { return .infinity }
    return abs(1 / inverse - pair.depth) / pair.depth
  }
  private static func median(_ values: [Float]) -> Float {
    let sorted = values.sorted()
    return sorted.isEmpty ? .infinity : sorted[sorted.count / 2]
  }
}

struct CoveragePoint: Equatable {
  let center: SIMD3<Float>
  let level: Int
}

/// Voxel map of surfaces seen during capture. A surface counts as covered once saved views have
/// seen it from three directions at least 15° apart, because reconstruction needs parallax,
/// not a single sighting.
struct CoverageMap {
  static let voxelSize: Float = 0.1
  static let coveredLevel = 3
  static let nearest: Float = 0.2
  static let farthest: Float = 6
  static let maximumCells = 60_000
  private static let distinctCosine = cos(Float.pi / 12)
  /// Largest change in inverse depth across ±2 pixels, relative to the centre. A wall viewed
  /// at 70° changes by about 1.5%; the model's blurred object edges change far faster.
  private static let edgeTolerance: Float = 0.06

  private(set) var cells = [SIMD3<Int32>: [SIMD3<Float>]]()

  /// Coverage for display. Monocular depth is noisy by roughly a voxel, so separate views of one
  /// surface often land in adjacent cells; each cell's level counts the distinct directions in
  /// its 3×3×3 neighbourhood rather than in the cell alone.
  func snapshot() -> (points: [CoveragePoint], coveredFraction: Double) {
    guard !cells.isEmpty else { return ([], 0) }
    var covered = 0
    let points = cells.keys.map { key -> CoveragePoint in
      var distinct = [SIMD3<Float>]()
      search: for dx: Int32 in -1...1 {
        for dy: Int32 in -1...1 {
          for dz: Int32 in -1...1 {
            for direction in cells[key &+ SIMD3(dx, dy, dz)] ?? []
            where distinct.allSatisfy({ simd_dot($0, direction) < Self.distinctCosine }) {
              distinct.append(direction)
              if distinct.count == Self.coveredLevel { break search }
            }
          }
        }
      }
      if distinct.count >= Self.coveredLevel { covered += 1 }
      return CoveragePoint(
        center: (SIMD3<Float>(key) + 0.5) * Self.voxelSize, level: distinct.count)
    }
    return (points, Double(covered) / Double(cells.count))
  }

  /// Adds one saved view. Returns false when the tracked points cannot scale the depth map.
  @discardableResult
  mutating func integrate(
    depth: RelativeDepthMap, camera: CoverageCamera, trackedPoints: [SIMD3<Float>],
    stride step: Int = 6
  ) -> Bool {
    let pairs = trackedPoints.compactMap { point -> (prediction: Float, depth: Float)? in
      guard let pixel = camera.project(point),
        let prediction = depth.sample(u: pixel.u, v: pixel.v)
      else { return nil }
      return (prediction, pixel.depth)
    }
    guard let line = DepthScale.fit(pairs) else { return false }
    func inverse(_ x: Int, _ y: Int) -> Float { line.a * depth.value(x, y) + line.b }
    for y in Swift.stride(from: 2, to: depth.height - 2, by: step) {
      for x in Swift.stride(from: 2, to: depth.width - 2, by: step) {
        let center = inverse(x, y)
        guard center > 1 / Self.farthest, center < 1 / Self.nearest else { continue }
        // The model blurs depth across object edges; those pixels would place points in the air
        // between surfaces.
        let neighbors = [
          inverse(x - 2, y), inverse(x + 2, y), inverse(x, y - 2), inverse(x, y + 2),
        ]
        guard neighbors.allSatisfy({ abs($0 - center) <= Self.edgeTolerance * center }) else {
          continue
        }
        let world = camera.unproject(u: Float(x), v: Float(y), depth: 1 / center)
        let key = SIMD3<Int32>(floor(world / Self.voxelSize))
        var directions = cells[key] ?? []
        guard cells[key] != nil || cells.count < Self.maximumCells else { continue }
        guard directions.count < Self.coveredLevel else { continue }
        let direction = simd_normalize(world - camera.position)
        if directions.allSatisfy({ simd_dot($0, direction) < Self.distinctCosine }) {
          directions.append(direction)
        }
        cells[key] = directions
      }
    }
    return true
  }
}
