import XCTest
import simd

@testable import CuseSublets

final class SpotTurnTests: XCTestCase {
  private func rotated(_ v: SIMD3<Float>, degrees: Float, axis: SIMD3<Float>) -> SIMD3<Float> {
    simd_quatf(angle: degrees * .pi / 180, axis: simd_normalize(axis)).act(v)
  }

  /// Holds the current target long enough to capture it.
  @discardableResult
  private func captureCurrent(_ turn: inout SpotTurn, at time: inout Double) -> SpotTurnEvent {
    let d = turn.direction(of: turn.current!)
    _ = turn.update(forward: d, time: time, steady: true)
    time += SpotTurn.holdDuration + 0.01
    let event = turn.update(forward: d, time: time, steady: true)
    time += 0.1
    return event
  }

  func testLayoutIsSixLevelShotsThenCeilingAndFloor() {
    XCTAssertEqual(SpotLayout.standard.count, 8)
    XCTAssertEqual(SpotLayout.standard.filter { $0.ring == 0 }.count, 6)
    XCTAssertEqual(SpotLayout.standard[6].pitch, .pi / 2)
    XCTAssertEqual(SpotLayout.standard[7].pitch, -.pi / 2)
  }

  func testHoldingOnTargetCapturesAfterHoldDuration() {
    var turn = SpotTurn(startYaw: 0)
    let d = turn.direction(of: turn.current!)
    XCTAssertEqual(turn.update(forward: d, time: 0, steady: true), .aligning)
    XCTAssertEqual(turn.update(forward: d, time: 0.49, steady: true), .aligning)
    XCTAssertEqual(turn.update(forward: d, time: 0.51, steady: true), .capture(index: 0))
    XCTAssertEqual(turn.captured, [0])
  }

  func testUnsteadyFrameResetsHold() {
    var turn = SpotTurn(startYaw: 0)
    let d = turn.direction(of: turn.current!)
    _ = turn.update(forward: d, time: 0, steady: true)
    _ = turn.update(forward: d, time: 0.3, steady: false)
    XCTAssertEqual(turn.holdProgress, 0)
    XCTAssertEqual(turn.update(forward: d, time: 0.6, steady: true), .aligning)
  }

  func testOffTargetBeyondToleranceDoesNotAlign() {
    var turn = SpotTurn(startYaw: 0)
    let d = rotated(turn.direction(of: turn.current!), degrees: 5, axis: [0, 1, 0])
    XCTAssertEqual(turn.update(forward: d, time: 0, steady: true), .none)
    XCTAssertEqual(turn.update(forward: d, time: 1, steady: true), .none)
    XCTAssertEqual(turn.holdProgress, 0)
    XCTAssertTrue(turn.captured.isEmpty)
  }

  func testRollDoesNotAffectAlignment() {
    // Only the camera's forward direction is used, so any roll about it gives the same input;
    // a tilt within tolerance still captures.
    var turn = SpotTurn(startYaw: 0.7)
    let target = turn.direction(of: turn.current!)
    let tilted = rotated(target, degrees: 3, axis: simd_cross(target, [0, 1, 0]))
    _ = turn.update(forward: tilted, time: 0, steady: true)
    XCTAssertEqual(turn.update(forward: tilted, time: 0.6, steady: true), .capture(index: 0))
  }

  func testStartYawRotatesTheFirstTarget() {
    let turn = SpotTurn(startYaw: .pi / 2)
    let d = turn.direction(of: turn.current!)
    // ARKit yaw about +Y: facing −Z at yaw 0, so yaw π/2 faces −X.
    XCTAssertEqual(d.x, -1, accuracy: 1e-5)
    XCTAssertEqual(d.z, 0, accuracy: 1e-5)
  }

  func testLevelRingFinishesBeforeUpperRing() {
    var turn = SpotTurn(startYaw: 0)
    var time = 0.0
    for _ in 0..<6 {
      XCTAssertEqual(turn.current?.ring, 0)
      captureCurrent(&turn, at: &time)
    }
    XCTAssertEqual(turn.current?.ring, 1)
  }

  func testTurningContinuesInOneDirection() {
    var turn = SpotTurn(startYaw: 0)
    var time = 0.0
    captureCurrent(&turn, at: &time)
    let second = turn.current!
    captureCurrent(&turn, at: &time)
    let third = turn.current!
    // Each next target is one 60° step further the same way.
    XCTAssertEqual(abs(second.yaw), .pi / 3, accuracy: 1e-5)
    XCTAssertEqual(third.yaw - second.yaw, second.yaw, accuracy: 1e-5)
  }

  func testUndoRemovesLastAndMakesItCurrent() {
    var turn = SpotTurn(startYaw: 0)
    var time = 0.0
    captureCurrent(&turn, at: &time)
    captureCurrent(&turn, at: &time)
    let last = turn.captured.last!
    XCTAssertEqual(turn.undo(), last)
    XCTAssertEqual(turn.captured.count, 1)
    XCTAssertEqual(turn.current, SpotLayout.standard[last])
    XCTAssertEqual(turn.holdProgress, 0)
  }

  func testUndoWithNothingCapturedReturnsNil() {
    var turn = SpotTurn(startYaw: 0)
    XCTAssertNil(turn.undo())
  }

  func testCompleteAfterAllTargets() {
    var turn = SpotTurn(startYaw: 0)
    var time = 0.0
    var last = SpotTurnEvent.none
    for _ in 0..<8 { last = captureCurrent(&turn, at: &time) }
    XCTAssertEqual(last, .complete)
    XCTAssertTrue(turn.isComplete)
    XCTAssertNil(turn.current)
    XCTAssertEqual(turn.progress, 1)
    XCTAssertEqual(Set(turn.captured), Set(0..<8))
  }
}
