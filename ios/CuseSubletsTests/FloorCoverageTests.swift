import XCTest
import simd

@testable import CuseSublets

final class FloorCoverageTests: XCTestCase {
  /// A 4 × 4 m room of floor cells on the 10 cm grid, x and z in 0..<40.
  private func room(excluding skip: (Int32, Int32) -> Bool = { _, _ in false }) -> [TopDownCell] {
    (0..<Int32(40)).flatMap { x in
      (0..<Int32(40)).compactMap { z in
        skip(x, z)
          ? nil
          : TopDownCell(x: x, z: z, floor: true, obstacle: false, top: 0, color: SIMD3(0.5, 0.5, 0.5))
      }
    }
  }

  func testEmptyRoomWithOneCentralSpotCoversDisc() {
    let fraction = FloorCoverage.fraction(cells: room(), spots: [SIMD2(2, 2)])
    XCTAssertEqual(fraction, Double.pi * 1.5 * 1.5 / 16, accuracy: 0.03)
  }

  func testWallBlocksSightLine() {
    // A wall along x = 2.0–2.1 m splits the room; the spot stands on the left half.
    var cells = room { x, _ in x == 20 }
    cells += (0..<Int32(40)).map {
      TopDownCell(x: 20, z: $0, floor: true, obstacle: true, top: 2.4, color: .zero)
    }
    let open = FloorCoverage.fraction(cells: room(), spots: [SIMD2(1.5, 2)])
    let walled = FloorCoverage.fraction(cells: cells, spots: [SIMD2(1.5, 2)])
    XCTAssertLessThan(walled, open - 0.05)
    // Nothing past the wall is covered: the left-half disc is all that counts.
    let leftOnly = FloorCoverage.fraction(
      cells: room { x, _ in x >= 20 }, spots: [SIMD2(1.5, 2)])
    let leftCells = Double(room { x, _ in x >= 20 }.count)
    let wallRoomFloor = Double(cells.filter { $0.floor && !$0.obstacle }.count)
    XCTAssertEqual(walled, leftOnly * leftCells / wallRoomFloor, accuracy: 0.001)
  }

  func testUnseenFloorDoesNotCount() {
    let full = FloorCoverage.fraction(cells: room(), spots: [SIMD2(0.5, 0.5)])
    // Only the corner the camera saw is in the map.
    let seen = FloorCoverage.fraction(cells: room { x, z in x > 20 || z > 20 }, spots: [SIMD2(0.5, 0.5)])
    XCTAssertGreaterThan(seen, full)
  }

  func testMoreSpotsNeverLowerCoverage() {
    let one = FloorCoverage.fraction(cells: room(), spots: [SIMD2(1, 1)])
    let two = FloorCoverage.fraction(cells: room(), spots: [SIMD2(1, 1), SIMD2(3, 3)])
    XCTAssertGreaterThan(two, one)
  }

  func testNoSpotsIsZero() {
    XCTAssertEqual(FloorCoverage.fraction(cells: room(), spots: []), 0)
    XCTAssertEqual(FloorCoverage.fraction(cells: [], spots: [SIMD2(1, 1)]), 0)
  }

  func testFloorFromLowestPlane() {
    XCTAssertEqual(
      FloorCoverage.estimateFloorY(planes: [-0.2, -1.4, 0.6], cells: [SIMD3(0, -3, 0)]), -1.4)
  }

  func testFloorFallsBackToPercentile() throws {
    var cells = (0..<95).map { SIMD3<Float>(0, Float($0) * 0.02 - 1.0, 0) }
    cells += (0..<5).map { _ in SIMD3<Float>(0, -5, 0) }  // stray points below the floor
    let floor = try XCTUnwrap(FloorCoverage.estimateFloorY(planes: [], cells: cells))
    XCTAssertEqual(floor, -1.0, accuracy: 0.05)
    XCTAssertNil(FloorCoverage.estimateFloorY(planes: [], cells: []))
  }
}
