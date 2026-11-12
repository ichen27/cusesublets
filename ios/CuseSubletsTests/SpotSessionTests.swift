import XCTest
import simd

@testable import CuseSublets

final class SpotSessionTests: XCTestCase {
  private func turning(_ session: inout SpotSession) -> Int {
    XCTAssertTrue(session.startSpot(budgetFits: true, tracking: true))
    guard case .turning(let spot) = session.phase else {
      XCTFail("expected turning, got \(session.phase)")
      return -1
    }
    return spot
  }

  func testSpotsAreNumberedFromOne() {
    var session = SpotSession()
    XCTAssertEqual(turning(&session), 1)
    session.spotFinished()
    XCTAssertEqual(turning(&session), 2)
  }

  func testFinishedSpotIsCompletedAndReturnsToMap() {
    var session = SpotSession()
    let spot = turning(&session)
    session.spotFinished()
    XCTAssertEqual(session.phase, .map)
    XCTAssertEqual(session.completed, [spot])
  }

  func testTrackingLossWhileTurningAbandonsSpotAndRelocates() {
    var session = SpotSession()
    _ = turning(&session)
    session.trackingChanged(normal: false)
    XCTAssertEqual(session.phase, .relocating)
    XCTAssertTrue(session.completed.isEmpty)
    // A late completion of the abandoned turn must not count.
    session.spotFinished()
    XCTAssertTrue(session.completed.isEmpty)
  }

  func testRelocatingReturnsToMapWhenNormal() {
    var session = SpotSession()
    _ = turning(&session)
    session.trackingChanged(normal: false)
    session.trackingChanged(normal: true)
    XCTAssertEqual(session.phase, .map)
  }

  func testTrackingLossOnTheMapDoesNotRelocateButBlocksStart() {
    var session = SpotSession()
    session.trackingChanged(normal: false)
    XCTAssertEqual(session.phase, .map)
    XCTAssertFalse(session.startSpot(budgetFits: true, tracking: false))
    XCTAssertEqual(session.phase, .map)
  }

  func testCannotStartNinthSpot() {
    var session = SpotSession()
    for _ in 0..<SpotTake.maximumSpots {
      _ = turning(&session)
      session.spotFinished()
    }
    XCTAssertFalse(session.startSpot(budgetFits: true, tracking: true))
    XCTAssertEqual(session.phase, .map)
  }

  func testDeletedSpotFreesASlot() {
    var session = SpotSession()
    for _ in 0..<SpotTake.maximumSpots {
      _ = turning(&session)
      session.spotFinished()
    }
    session.deleteSpot(3)
    XCTAssertEqual(turning(&session), SpotTake.maximumSpots + 1)
  }

  func testCannotStartWhenBudgetFull() {
    var session = SpotSession()
    XCTAssertFalse(session.startSpot(budgetFits: false, tracking: true))
    XCTAssertEqual(session.phase, .map)
  }

  func testCannotStartWhileTurning() {
    var session = SpotSession()
    _ = turning(&session)
    XCTAssertFalse(session.startSpot(budgetFits: true, tracking: true))
  }

  func testAbandonedTurnCanBeAbandonedExplicitly() {
    var session = SpotSession()
    _ = turning(&session)
    session.abandonSpot()
    XCTAssertEqual(session.phase, .map)
    XCTAssertTrue(session.completed.isEmpty)
  }

  func testInterruptionKeepsCompletedSpots() {
    var session = SpotSession()
    let first = turning(&session)
    session.spotFinished()
    _ = turning(&session)
    session.interrupted()
    XCTAssertEqual(session.phase, .ended(reason: "Capture ended. Your finished spots are saved."))
    XCTAssertEqual(session.completed, [first])
    XCTAssertFalse(session.startSpot(budgetFits: true, tracking: true))
  }

  func testRecoveredSessionContinuesNumbering() {
    var session = SpotSession(completed: [1, 2, 4])
    XCTAssertEqual(turning(&session), 5)
  }

  func testCanGenerateNeedsOneSpot() {
    var session = SpotSession()
    XCTAssertFalse(session.canGenerate)
    _ = turning(&session)
    XCTAssertFalse(session.canGenerate)
    session.spotFinished()
    XCTAssertTrue(session.canGenerate)
    session.deleteSpot(1)
    XCTAssertFalse(session.canGenerate)
  }

  func testWalkPolicyForSpotTakesOutlastsThreeMinutes() {
    var policy = CapturePolicy(maximumViews: SpotTake.maximumWalkFrames, maximumDuration: .infinity)
    func sample(_ time: Double, x: Float) -> CaptureSample {
      CaptureSample(
        time: time, position: SIMD3(x, 0, 0), forward: SIMD3(0, 0, -1), tracking: true,
        exposure: 1.0 / 120, focalLength: 1450, sceneDepth: 2, featureCount: 200)
    }
    _ = policy.evaluate(sample(600, x: 0))
    XCTAssertEqual(policy.evaluate(sample(600.5, x: 0.15)).reason, .saved)
  }
}
