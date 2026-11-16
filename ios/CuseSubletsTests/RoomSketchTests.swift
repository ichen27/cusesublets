import XCTest
import simd

@testable import CuseSublets

final class RoomSketchTests: XCTestCase {
  private let cameraHeight: Float = 1.4
  /// Half the width of a square room with the spot in the middle.
  private let wall: Float = 2

  /// A 40 × 30 slice of one colour, about 107° × 90° like the 0.5× lens.
  private func slice(_ colour: SIMD3<UInt8>, _ cameraToWorld: simd_float3x3) -> FloorView {
    var pixels = [UInt8]()
    for _ in 0..<(40 * 30) { pixels += [colour.x, colour.y, colour.z, 255] }
    return FloorView(
      pixels: pixels, width: 40, height: 30, fx: 15, fy: 15, cx: 20, cy: 15,
      cameraToWorld: cameraToWorld)
  }

  /// Six level slices, upright, every 60°, and a floor shot.
  private var slices: [FloorView] {
    let level = simd_float3x3(SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1))
    var all = (0..<6).map { index -> FloorView in
      let turn = simd_float3x3(simd_quatf(angle: Float(index) * .pi / 3, axis: SIMD3(0, 1, 0)))
      return slice(SIMD3(180, 170, 160), turn * level)
    }
    all.append(slice(SIMD3(120, 100, 80), simd_float3x3(SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0))))
    return all
  }

  /// Depth along a view's axis to the floor or the nearest wall of the square room.
  private func trueDepth(_ world: SIMD3<Float>) -> Float {
    var nearest = Float.infinity
    if world.y < 0 { nearest = min(nearest, cameraHeight / -world.y) }
    for axis in [world.x, world.z] where abs(axis) > 1e-6 { nearest = min(nearest, wall / abs(axis)) }
    return nearest
  }

  /// What a perfect depth model would say, up to the unknown scale and offset a real one has.
  private func model(_ index: Int, _: [UInt8]) -> [Float]? {
    let rotation = RoomSketch.rotation(
      yaw: 2 * .pi * Float(index) / Float(RoomSketch.viewCount), pitch: RoomSketch.pitch)
    var values = [Float]()
    for row in 0..<RoomSketch.height {
      for column in 0..<RoomSketch.width {
        let depth = trueDepth(rotation * RoomSketch.ray(column: column, row: row))
        values.append((1 / depth - 0.2) / 1.5)
      }
    }
    return values
  }

  func testViewsLookDownIntoTheRoomAndTurnLeft() {
    let ahead = RoomSketch.rotation(yaw: 0, pitch: RoomSketch.pitch) * SIMD3<Float>(0, 0, -1)
    XCTAssertEqual(ahead.x, 0, accuracy: 1e-5)
    XCTAssertLessThan(ahead.z, -0.8)
    XCTAssertEqual(ahead.y, sin(RoomSketch.pitch), accuracy: 1e-5)
    let left = RoomSketch.rotation(yaw: .pi / 2, pitch: 0) * SIMD3<Float>(0, 0, -1)
    XCTAssertEqual(simd_distance(left, SIMD3(-1, 0, 0)), 0, accuracy: 1e-5)
    // Upright: the view's "up" has no sideways lean.
    let up = RoomSketch.rotation(yaw: 1, pitch: RoomSketch.pitch) * SIMD3<Float>(1, 0, 0)
    XCTAssertEqual(up.y, 0, accuracy: 1e-5)
  }

  func testScaleIsFoundWhenFurnitureHidesAlmostHalfTheFloor() throws {
    var prediction = [Float]()
    var expected = [Float]()
    for index in 0..<600 {
      let p = Float(index % 97) / 97
      prediction.append(p)
      // Floor follows 0.8·p + 0.3; every other pixel but one is furniture, nearer than the floor.
      let furniture = index % 20 < 9
      expected.append((0.8 * p + 0.3) * (furniture ? 0.5 + Float(index % 7) * 0.04 : 1))
    }
    let line = try XCTUnwrap(RoomSketch.scale(prediction: prediction, expected: expected))
    XCTAssertEqual(line.a, 0.8, accuracy: 0.02)
    XCTAssertEqual(line.b, 0.3, accuracy: 0.02)
    XCTAssertEqual(line.agreement, 0.55, accuracy: 0.05)
  }

  func testScaleIsRefusedWhenNothingAgrees() {
    var prediction = [Float]()
    var expected = [Float]()
    for index in 0..<400 {
      prediction.append(Float(index % 31) / 31)
      expected.append(0.2 + Float((index * 7919) % 101) / 50)
    }
    XCTAssertNil(RoomSketch.scale(prediction: prediction, expected: expected))
    XCTAssertNil(RoomSketch.scale(prediction: [0.1, 0.2], expected: [0.3, 0.4]))
  }

  func testPointsStayInsideTheRoomAndReachItsWalls() {
    let points = RoomSketch.points(slices: slices, cameraHeight: cameraHeight, depth: model)
    XCTAssertGreaterThan(points.count, RoomSketch.minimumPoints)
    var farthest: Float = 0
    for point in points {
      let p = point.position
      XCTAssertLessThan(max(abs(p.x), abs(p.z)), wall + 0.05)
      XCTAssertGreaterThan(p.y, -cameraHeight - 0.05)
      farthest = max(farthest, abs(p.x), abs(p.z))
    }
    XCTAssertGreaterThan(farthest, wall - 0.05)
  }

  func testThePictureHasTheRoomsShape() {
    let points = RoomSketch.points(slices: slices, cameraHeight: cameraHeight, depth: model)
    let side = 100
    let rgba = RoomSketch.picture(points: points, cameraHeight: cameraHeight, side: side, radius: 4)
    func alpha(x: Float, z: Float) -> UInt8 {
      let column = Int((x / 4 + 1) / 2 * Float(side))
      let row = Int((z / 4 + 1) / 2 * Float(side))
      return rgba[(row * side + column) * 4 + 3]
    }
    // Floor in front of the spot is drawn; beyond the walls nothing is.
    XCTAssertEqual(alpha(x: 0.1, z: -1.2), 255)
    XCTAssertEqual(alpha(x: 1.2, z: 0.1), 255)
    XCTAssertEqual(alpha(x: 0.1, z: -2.6), 0)
    XCTAssertEqual(alpha(x: 3, z: 3), 0)
    var outside = 0
    for row in 0..<side {
      for column in 0..<side where rgba[(row * side + column) * 4 + 3] > 0 {
        let x = ((Float(column) + 0.5) / Float(side) * 2 - 1) * 4
        let z = ((Float(row) + 0.5) / Float(side) * 2 - 1) * 4
        if max(abs(x), abs(z)) > wall + 0.15 { outside += 1 }
      }
    }
    XCTAssertEqual(outside, 0)
  }

  func testTheHighestSurfaceBelowTheCeilingShows() {
    let rgba = RoomSketch.picture(
      points: [
        RoomPoint(position: SIMD3(0.5, -1.4, 0.5), colour: SIMD3(10, 10, 10)),  // floor
        RoomPoint(position: SIMD3(0.5, -0.6, 0.5), colour: SIMD3(200, 0, 0)),  // table top
        RoomPoint(position: SIMD3(0.5, 1.0, 0.5), colour: SIMD3(0, 0, 200)),  // ceiling
      ], cameraHeight: 1.4, side: 10, radius: 5)
    let cell = (5 * 10 + 5) * 4
    XCTAssertEqual(Array(rgba[cell..<(cell + 4)]), [200, 0, 0, 255])
  }

  func testNoModelMeansNoPoints() {
    XCTAssertTrue(
      RoomSketch.points(slices: slices, cameraHeight: cameraHeight) { _, _ in nil }.isEmpty)
  }
}
