import XCTest
import simd

@testable import CuseSublets

final class CapturePolicyTests: XCTestCase {
  private let ahead = SIMD3<Float>(0, 0, -1)

  /// One ARKit frame: indoor exposure 1/60 s, a 1920-pixel-wide image, a wall 2 m away.
  private func sample(
    _ time: Double, at position: SIMD3<Float> = .zero, facing forward: SIMD3<Float>? = nil,
    tracking: Bool = true, exposure: Double = 1.0 / 60, depth: Float? = 2, features: Int = 200
  ) -> CaptureSample {
    CaptureSample(
      time: time, position: position, forward: forward ?? ahead, tracking: tracking,
      exposure: exposure, focalLength: 1450, sceneDepth: depth, featureCount: features)
  }

  private func facing(yaw: Float) -> SIMD3<Float> { SIMD3(-sin(yaw), 0, -cos(yaw)) }

  /// Two frames 1/30 s apart, so the policy can measure motion before the second; only the
  /// second may save.
  @discardableResult
  private func settle(_ policy: inout CapturePolicy, _ second: CaptureSample) -> CaptureDecision {
    var first = second
    first.time -= 1.0 / 30
    _ = policy.evaluate(first, canSave: false)
    return policy.evaluate(second)
  }

  func testWaitsForTrackingAndAMotionEstimateBeforeTheFirstView() {
    var policy = CapturePolicy()
    XCTAssertFalse(policy.evaluate(sample(0, tracking: false)).save)
    let first = policy.evaluate(sample(1))
    XCTAssertFalse(first.save, "one frame cannot tell whether the camera is moving")
    XCTAssertTrue(policy.evaluate(sample(1 + 1.0 / 30)).save)
  }

  func testRejectsFastMotion() {
    var policy = CapturePolicy()
    settle(&policy, sample(1))
    let decision = policy.evaluate(sample(1.1, at: SIMD3(0.1, 0, 0)))
    XCTAssertFalse(decision.save)
    XCTAssertEqual(decision.hint, .slowDown)
    XCTAssertFalse(decision.usable, "fast frames are blurred, so they must not paint coverage")
  }

  func testRejectsMotionBlurThatTheSpeedLimitAllows() {
    // Turning at 0.4 rad/s (23°/s) is under the speed limit, but a 1/30 s indoor exposure smears
    // the image by 0.4 × 1/30 × 1450 ≈ 19 pixels.
    var policy = CapturePolicy()
    let step: Float = 0.4 / 30
    _ = policy.evaluate(sample(1, facing: facing(yaw: 0), exposure: 1.0 / 30))
    let blurred = policy.evaluate(
      sample(1 + 1.0 / 30, facing: facing(yaw: step), exposure: 1.0 / 30))
    XCTAssertFalse(blurred.save)
    XCTAssertEqual(blurred.hint, .holdSteadier)
    // The same turn in bright light (1/250 s) smears it by about 2 pixels.
    var bright = CapturePolicy()
    _ = bright.evaluate(sample(1, facing: facing(yaw: 0), exposure: 1.0 / 250))
    XCTAssertTrue(
      bright.evaluate(sample(1 + 1.0 / 30, facing: facing(yaw: step), exposure: 1.0 / 250)).save)
  }

  func testSidewaysStepNeededForANewViewGrowsWithDistanceToTheRoom() {
    for (depth, step, saves) in [
      (Float(1), Float(0.07), true), (3, 0.07, false), (3, 0.19, true),
    ] {
      var policy = CapturePolicy()
      XCTAssertTrue(settle(&policy, sample(1, depth: depth)).save)
      let decision = settle(&policy, sample(2, at: SIMD3(step, 0, 0), depth: depth))
      XCTAssertEqual(decision.save, saves, "step \(step) m with the room \(depth) m away")
    }
  }

  func testTurningInPlaceSavesTwoViewsThenAsksForAStep() {
    var policy = CapturePolicy()
    XCTAssertTrue(settle(&policy, sample(1, facing: facing(yaw: 0))).save)
    XCTAssertTrue(settle(&policy, sample(2, facing: facing(yaw: 0.3))).save)
    XCTAssertTrue(settle(&policy, sample(3, facing: facing(yaw: 0.6))).save)
    let third = settle(&policy, sample(4, facing: facing(yaw: 0.9)))
    XCTAssertFalse(third.save)
    XCTAssertEqual(third.hint, .stepSideways)
    XCTAssertTrue(third.usable, "the view still paints the overlay; it just is not saved")
    // A real step clears the limit.
    XCTAssertTrue(settle(&policy, sample(5, at: SIMD3(0.2, 0, 0), facing: facing(yaw: 0.9))).save)
    XCTAssertTrue(settle(&policy, sample(6, at: SIMD3(0.2, 0, 0), facing: facing(yaw: 1.2))).save)
  }

  func testSmallTurnsAndDriftDoNotSaveDuplicateViews() {
    var policy = CapturePolicy()
    XCTAssertTrue(settle(&policy, sample(1)).save)
    let decision = settle(&policy, sample(2, at: SIMD3(0.03, 0, 0), facing: facing(yaw: 0.1)))
    XCTAssertEqual(decision, CaptureDecision(save: false, usable: true, hint: nil))
  }

  func testFeaturelessViewsAreRejectedWithGuidance() {
    var blank = CapturePolicy()
    let wall = settle(&blank, sample(1, features: 20))
    XCTAssertEqual(wall, CaptureDecision(save: false, usable: false, hint: .findDetail))
  }

  func testOrdinaryCaptureShowsNoText() {
    // Moving slowly, holding still and saving are all normal; the overlay is the guidance.
    var policy = CapturePolicy()
    XCTAssertNil(settle(&policy, sample(1)).hint)
    XCTAssertNil(policy.evaluate(sample(1.1)).hint)
    XCTAssertNil(settle(&policy, sample(2, at: SIMD3(0.2, 0, 0))).hint)
  }

  func testHintsAppearOnlyOnceAProblemLasts() {
    var filter = CaptureHintFilter()
    XCTAssertNil(filter.update(.slowDown, at: 0))
    XCTAssertNil(filter.update(.slowDown, at: 0.4))
    XCTAssertEqual(filter.update(.slowDown, at: 0.7), .slowDown)
    // A good frame does not make the hint flicker off at once.
    XCTAssertEqual(filter.update(nil, at: 0.8), .slowDown)
    XCTAssertNil(filter.update(nil, at: 1.4))
    // A brief blip never shows.
    XCTAssertNil(filter.update(.holdSteadier, at: 2))
    XCTAssertNil(filter.update(nil, at: 2.1))
    XCTAssertNil(filter.update(.holdSteadier, at: 2.2))
  }

  func testStepHintWaitsLongerThanMotionHints() {
    var filter = CaptureHintFilter()
    XCTAssertNil(filter.update(.stepSideways, at: 0))
    XCTAssertNil(filter.update(.stepSideways, at: 1))
    XCTAssertEqual(filter.update(.stepSideways, at: 1.5), .stepSideways)
  }

  func testWaitsWhileThePreviousViewIsStillSaving() {
    var policy = CapturePolicy()
    _ = policy.evaluate(sample(1))
    XCTAssertFalse(policy.evaluate(sample(1 + 1.0 / 30), canSave: false).save)
    XCTAssertEqual(policy.count, 0)
    XCTAssertTrue(policy.evaluate(sample(1 + 2.0 / 30)).save)
  }

  func testStopsAtTheProcessingLimit() {
    var policy = CapturePolicy()
    var time = 1.0
    var saved = 0
    for index in 0..<400 {
      time += 0.5
      if settle(&policy, sample(time, at: SIMD3(Float(index) * 0.2, 0, 0))).save { saved += 1 }
    }
    XCTAssertEqual(saved, CapturePolicy.maximumViews)
  }

  func testMedianDepthMeasuresAlongTheViewAxis() throws {
    var transform = matrix_identity_float4x4
    transform.columns.3 = SIMD4(0, 0, 1, 1)
    let points: [SIMD3<Float>] = [
      SIMD3(0, 0, -1), SIMD3(0.5, 0, -2), SIMD3(0, 0.3, -3), SIMD3(0, 0, 5), SIMD3(9, 0, -9),
    ]
    // Distances along -z from z = 1: 2, 3, 4 and 10; the point behind the camera is ignored.
    XCTAssertEqual(try XCTUnwrap(CaptureSample.medianDepth(points, camera: transform)), 4)
    XCTAssertNil(CaptureSample.medianDepth([SIMD3(0, 0, 5)], camera: transform))
  }
}
