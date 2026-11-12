import XCTest
import simd

@testable import CuseSublets

final class CaptureCoverageTests: XCTestCase {
  // The model's output is an unknown affine transform of inverse depth; the fit must recover it.
  private let modelScale: Float = 0.7
  private let modelShift: Float = -0.05

  func testDepthScaleRecoversAffineInverseDepthDespiteOutliers() throws {
    var pairs = stride(from: Float(0.5), through: 4, by: 0.25).map { z in
      (prediction: (1 / z - modelShift) / modelScale, depth: z)
    }
    pairs += [(prediction: 0.1, depth: 0.6), (prediction: 2.5, depth: 5)]
    let line = try XCTUnwrap(DepthScale.fit(pairs))
    XCTAssertEqual(line.a, modelScale, accuracy: 0.01)
    XCTAssertEqual(line.b, modelShift, accuracy: 0.01)
  }

  func testTooFewTrackedPointsLeavesMapEmpty() {
    var map = CoverageMap()
    let camera = camera(at: .zero, yaw: 0)
    let points = wallPoints(seenBy: camera).prefix(DepthScale.minimumPoints - 1)
    XCTAssertFalse(
      map.integrate(depth: wall(seenBy: camera), camera: camera, trackedPoints: Array(points)))
    XCTAssertTrue(map.cells.isEmpty)
  }

  func testSingleViewMarksWallCellsAsSeenOnce() throws {
    var map = CoverageMap()
    let camera = camera(at: .zero, yaw: 0)
    XCTAssertTrue(
      map.integrate(
        depth: wall(seenBy: camera), camera: camera, trackedPoints: wallPoints(seenBy: camera)))
    XCTAssertGreaterThan(map.cells.count, 200)
    let snapshot = map.snapshot()
    for point in snapshot.points {
      XCTAssertEqual(point.center.z, -wallDistance, accuracy: CoverageMap.voxelSize)
      XCTAssertEqual(point.level, 1)
    }
    XCTAssertEqual(snapshot.coveredFraction, 0)
  }

  func testRepeatedViewDoesNotCountAsANewAngle() {
    var map = CoverageMap()
    let camera = camera(at: .zero, yaw: 0)
    for _ in 0..<3 {
      map.integrate(
        depth: wall(seenBy: camera), camera: camera, trackedPoints: wallPoints(seenBy: camera))
    }
    XCTAssertTrue(map.snapshot().points.allSatisfy { $0.level == 1 })
  }

  func testDistinctAnglesRaiseCoverageUntilCovered() throws {
    var map = CoverageMap()
    for camera in [
      camera(at: .zero, yaw: 0), camera(at: SIMD3(1.2, 0, 0), yaw: 0.54),
      camera(at: SIMD3(-1.2, 0, 0), yaw: -0.54),
    ] {
      XCTAssertTrue(
        map.integrate(
          depth: wall(seenBy: camera), camera: camera, trackedPoints: wallPoints(seenBy: camera)))
    }
    let snapshot = map.snapshot()
    let center = try XCTUnwrap(
      snapshot.points.min { simd_length($0.center.xy) < simd_length($1.center.xy) })
    XCTAssertEqual(center.level, CoverageMap.coveredLevel)
    XCTAssertGreaterThan(snapshot.coveredFraction, 0.1)
    XCTAssertLessThan(snapshot.coveredFraction, 1)
  }

  func testNoisyDepthFromAnotherAngleStillCountsForTheSameSurface() throws {
    var map = CoverageMap()
    let front = camera(at: .zero, yaw: 0)
    map.integrate(
      depth: wall(seenBy: front), camera: front, trackedPoints: wallPoints(seenBy: front))
    // The second view places the same wall 8 cm deeper, across a cell boundary.
    let side = camera(at: SIMD3(1.2, 0, 0), yaw: 0.54)
    map.integrate(
      depth: wall(seenBy: side, at: 2.13), camera: side,
      trackedPoints: wallPoints(seenBy: side, at: 2.13))
    let center = try XCTUnwrap(
      map.snapshot().points.filter { $0.center.z > -2.1 }
        .min { simd_length($0.center.xy) < simd_length($1.center.xy) })
    XCTAssertEqual(center.level, 2)
  }

  func testDepthEdgesDoNotCreateCellsBetweenSurfaces() {
    var map = CoverageMap()
    let camera = camera(at: .zero, yaw: 0)
    // Left: a box face 1 m away. Right: the wall 3 m away. Like the model, blur the edge over
    // 18 pixels instead of stepping, so in-between depths exist for the filter to reject.
    let depth = depthMap(camera) { x, _ in
      let t = min(1, max(0, Float(x - 250) / 18))
      return 1 / (1 + t * (1.0 / 3 - 1))
    }
    let points = (0..<40).map { i -> SIMD3<Float> in
      let near = i.isMultiple(of: 2)
      let u = near ? Float(40 + i * 4) : Float(300 + i * 4)
      return camera.unproject(u: u, v: Float(80 + i * 5), depth: near ? 1 : 3)
    }
    XCTAssertTrue(map.integrate(depth: depth, camera: camera, trackedPoints: points))
    XCTAssertFalse(map.snapshot().points.contains { $0.center.z < -1.2 && $0.center.z > -2.8 })
  }

  func testIntegrateRecordsCellColour() throws {
    var map = CoverageMap()
    let camera = camera(at: .zero, yaw: 0)
    XCTAssertTrue(
      map.integrate(
        depth: wall(seenBy: camera), camera: camera, trackedPoints: wallPoints(seenBy: camera),
        colors: { _, _ in SIMD3(1, 0, 0) }))
    let cells = map.topDown(floorY: -1.0)
    XCTAssertFalse(cells.isEmpty)
    for cell in cells { XCTAssertEqual(cell.color, SIMD3(1, 0, 0)) }
  }

  func testTopDownMarksFloorAndObstacleColumns() throws {
    var map = CoverageMap()
    let camera = camera(at: .zero, yaw: 0)
    map.integrate(
      depth: wall(seenBy: camera), camera: camera, trackedPoints: wallPoints(seenBy: camera))
    // The wall spans y from about −1.0 to +1.0 m in front of the camera.
    let cells = map.topDown(floorY: -1.0)
    XCTAssertTrue(cells.contains { $0.floor })
    XCTAssertTrue(cells.allSatisfy { $0.obstacle })
    XCTAssertTrue(map.topDown(floorY: -5).allSatisfy { !$0.floor })
  }

  // MARK: - Synthetic scene: a flat wall at z = -2 m seen by 518×392 depth maps.

  // 2.05 m keeps the exact synthetic wall mid-voxel rather than on a cell boundary.
  private let wallDistance: Float = 2.05

  private func camera(at position: SIMD3<Float>, yaw: Float) -> CoverageCamera {
    var transform = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
    transform.columns.3 = SIMD4(position, 1)
    return CoverageCamera(fx: 400, fy: 400, cx: 259, cy: 196, transform: transform)
  }

  /// Model-style output for a pinhole camera, given each pixel's distance along the view axis.
  private func depthMap(_ camera: CoverageCamera, _ depth: (Int, Int) -> Float) -> RelativeDepthMap
  {
    var values = [Float]()
    for y in 0..<392 {
      for x in 0..<518 { values.append((1 / depth(x, y) - modelShift) / modelScale) }
    }
    return RelativeDepthMap(width: 518, height: 392, values: values)
  }

  private func wall(seenBy camera: CoverageCamera, at distance: Float? = nil) -> RelativeDepthMap {
    depthMap(camera) { x, y in
      self.wallDepth(camera, u: Float(x), v: Float(y), distance: distance ?? self.wallDistance)
    }
  }

  private func wallDepth(_ camera: CoverageCamera, u: Float, v: Float, distance: Float) -> Float {
    // Intersect the pixel ray with the wall plane, then measure along the camera axis.
    let hit = camera.unproject(u: u, v: v, depth: 1)
    let origin = camera.position
    return (-distance - origin.z) / (hit.z - origin.z)
  }

  private func wallPoints(seenBy camera: CoverageCamera, at distance: Float? = nil)
    -> [SIMD3<Float>]
  {
    stride(from: Float(30), to: 500, by: 40).flatMap { u in
      stride(from: Float(30), to: 370, by: 60).map { v in
        camera.unproject(
          u: u, v: v,
          depth: wallDepth(camera, u: u, v: v, distance: distance ?? wallDistance))
      }
    }
  }
}

extension SIMD3 where Scalar == Float {
  fileprivate var xy: SIMD2<Float> { SIMD2(x, y) }
}
