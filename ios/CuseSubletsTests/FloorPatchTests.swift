import XCTest
import simd

@testable import CuseSublets

final class FloorPatchTests: XCTestCase {
  /// A 40 × 30 view of one colour; `personSide` paints the half towards the person another.
  private func view(
    _ colour: SIMD3<UInt8>, cameraToWorld: simd_float3x3, personSide: SIMD3<UInt8>? = nil
  ) -> FloorView {
    var pixels = [UInt8]()
    for _ in 0..<30 {
      for column in 0..<40 {
        let c = (personSide != nil && column >= 24) ? personSide! : colour
        pixels += [c.x, c.y, c.z, 255]
      }
    }
    // About 107° × 90°, like the 0.5× lens.
    return FloorView(
      pixels: pixels, width: 40, height: 30, fx: 15, fy: 15, cx: 20, cy: 15,
      cameraToWorld: cameraToWorld)
  }

  /// Aimed straight down, held upright: the top of the phone points to −z (away from the
  /// person), so the camera's x (the phone's bottom edge) points to +z.
  private let down = simd_float3x3(SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0))

  private func pixel(_ rgba: [UInt8], side: Int, column: Int, row: Int) -> SIMD4<UInt8> {
    let i = (row * side + column) * 4
    return SIMD4(rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3])
  }

  func testFloorBelowTheCameraTakesTheFloorShotsColour() {
    let side = 64
    let rgba = FloorPatch.compose(
      views: [view(SIMD3(200, 100, 50), cameraToWorld: down)], cameraHeight: 1.4, side: side, radius: 2.5)
    // Just on the far side of straight down.
    let seen = pixel(rgba, side: side, column: side / 2, row: side / 2 - 3)
    XCTAssertEqual(seen.w, 255)
    XCTAssertEqual(Int(seen.x), 200, accuracy: 2)
    XCTAssertEqual(Int(seen.y), 100, accuracy: 2)
  }

  func testThePersonsSideOfTheFloorShotIsLeftOut() {
    let side = 64
    let rgba = FloorPatch.compose(
      views: [view(SIMD3(200, 100, 50), cameraToWorld: down, personSide: SIMD3(255, 0, 0))],
      cameraHeight: 1.4, side: side, radius: 2.5)
    // 0.6 m towards the person (+z): only the floor shot sees it, and it shows their legs.
    let behind = pixel(rgba, side: side, column: side / 2, row: side / 2 + 8)
    XCTAssertEqual(behind.w, 0)
    for row in 0..<side {
      for column in 0..<side {
        let p = pixel(rgba, side: side, column: column, row: row)
        XCTAssertFalse(p.w > 0 && p.x > 220 && p.y < 30, "person colour at \(column), \(row)")
      }
    }
  }

  func testALevelShotCoversTheFloorInFrontAndFadesAtTheEdge() {
    // Level, upright, looking to −z: camera x points down, y to the right (+x), z to +z.
    let level = simd_float3x3(SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1))
    let side = 64
    let rgba = FloorPatch.compose(
      views: [view(SIMD3(10, 180, 90), cameraToWorld: level)], cameraHeight: 1.4, side: side, radius: 2.5)
    // 1.4 m ahead is 45° down: inside the lens's 53° half view.
    let ahead = pixel(rgba, side: side, column: side / 2, row: side / 2 - 18)
    XCTAssertEqual(ahead.w, 255)
    XCTAssertEqual(Int(ahead.y), 180, accuracy: 2)
    // Behind the camera nothing was seen.
    XCTAssertEqual(pixel(rgba, side: side, column: side / 2, row: side / 2 + 18).w, 0)
    // Near the rim the picture has faded out.
    XCTAssertLessThan(pixel(rgba, side: side, column: side / 2, row: 1).w, 40)
  }

  func testNothingIsDrawnWithoutACameraHeight() {
    let rgba = FloorPatch.compose(
      views: [view(SIMD3(200, 100, 50), cameraToWorld: down)], cameraHeight: 0, side: 16)
    XCTAssertTrue(rgba.allSatisfy { $0 == 0 })
  }
}
