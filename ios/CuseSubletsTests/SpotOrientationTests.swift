import XCTest
import simd

@testable import CuseSublets

final class SpotOrientationTests: XCTestCase {
  /// Phone upright in portrait, back camera facing world −Z: ARKit's camera x axis (towards
  /// the bottom of the phone) points down, and its y axis (the phone's right edge) points +X.
  private let uprightCamera = simd_float3x3(
    SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1))
  /// The same pose as a device-to-reference rotation, for a reference frame whose z is up and
  /// whose x happens to match world +X: device x → ref x, device y (top) → ref z, device z → −ref y.
  private let uprightDevice = simd_float3x3(
    SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, -1, 0))

  private func rotation(aboutUp angle: Float) -> simd_float3x3 {
    // Reference-frame rotation about its vertical (z) axis.
    simd_float3x3(simd_quatf(angle: angle, axis: SIMD3(0, 0, 1)))
  }

  func testStartPoseFacesWhereArkitSaid() {
    let o = SpotOrientation(cameraToWorld: uprightCamera, deviceToReference: uprightDevice)
    let forward = o.forward(uprightDevice)
    XCTAssertEqual(simd_distance(forward, SIMD3(0, 0, -1)), 0, accuracy: 1e-5)
    XCTAssertEqual(o.gravityMismatchDegrees, 0, accuracy: 0.01)
    let camera = o.cameraToWorld(uprightDevice)
    XCTAssertEqual(simd_distance(camera.columns.2, uprightCamera.columns.2), 0, accuracy: 1e-5)
    XCTAssertEqual(simd_distance(camera.columns.0, uprightCamera.columns.0), 0, accuracy: 1e-5)
  }

  func testTurningLeftByNinetyDegreesFacesWorldMinusX() {
    let o = SpotOrientation(cameraToWorld: uprightCamera, deviceToReference: uprightDevice)
    // Counter-clockwise seen from above is a left turn; from −Z that faces −X.
    let turned = rotation(aboutUp: .pi / 2) * uprightDevice
    XCTAssertEqual(simd_distance(o.forward(turned), SIMD3(-1, 0, 0)), 0, accuracy: 1e-5)
  }

  func testTiltingUpRaisesForward() {
    let o = SpotOrientation(cameraToWorld: uprightCamera, deviceToReference: uprightDevice)
    // Tip the top of the phone back towards the user: rotate about the device's x axis.
    let tilt = simd_float3x3(simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0)))
    let forward = o.forward(uprightDevice * tilt)
    XCTAssertEqual(simd_distance(forward, SIMD3(0, 1, 0)), 0, accuracy: 1e-5)
  }

  func testAttitudeDirectionIsSettledByGravity() {
    // Gravity in the device frame for the upright pose: towards the bottom of the phone.
    let gravity = SIMD3<Float>(0, -1, 0)
    let fromDeviceToReference = SpotOrientation.deviceToReference(
      matrix: uprightDevice, gravity: gravity)
    let fromReferenceToDevice = SpotOrientation.deviceToReference(
      matrix: uprightDevice.transpose, gravity: gravity)
    for result in [fromDeviceToReference, fromReferenceToDevice] {
      XCTAssertEqual(simd_distance(result.columns.1, uprightDevice.columns.1), 0, accuracy: 1e-5)
    }
  }

  func testDotStraightAheadIsAtScreenCentreAndRightIsRight() {
    let o = SpotOrientation(cameraToWorld: uprightCamera, deviceToReference: uprightDevice)
    let screen = CGSize(width: 390, height: 844)
    let image = CGSize(width: 1920, height: 1440)
    let ahead = o.screenPoint(
      of: SIMD3(0, 0, -1), deviceToReference: uprightDevice, focal: 700, image: image,
      screen: screen)
    XCTAssertTrue(ahead.ahead)
    XCTAssertEqual(ahead.point.x, 195, accuracy: 0.01)
    XCTAssertEqual(ahead.point.y, 422, accuracy: 0.01)
    let rightAndUp = o.screenPoint(
      of: simd_normalize(SIMD3(0.2, 0.2, -1)), deviceToReference: uprightDevice, focal: 700,
      image: image, screen: screen)
    XCTAssertGreaterThan(rightAndUp.point.x, 195)
    XCTAssertLessThan(rightAndUp.point.y, 422)
    let behind = o.screenPoint(
      of: SIMD3(0, 0, 1), deviceToReference: uprightDevice, focal: 700, image: image,
      screen: screen)
    XCTAssertFalse(behind.ahead)
  }

  // MARK: Lining tracking up again after a turn

  private func pose(_ rotation: simd_float3x3, at p: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
      SIMD4(rotation.columns.0, 0), SIMD4(rotation.columns.1, 0), SIMD4(rotation.columns.2, 0),
      SIMD4(p, 1))
  }

  private func turn(_ degrees: Float) -> simd_float3x3 {
    simd_float3x3(simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0)))
  }

  func testRealignmentUndoesARestartedSessionsTurnAndShift() {
    // The camera really is here, tilted down a little and facing 40° left.
    let tilt = simd_float3x3(simd_quatf(angle: -0.5, axis: SIMD3(1, 0, 0)))
    let truth = turn(40) * tilt
    let place = SIMD3<Float>(2, 1.4, -3)
    // The restarted session calls its own heading 0 and starts near its own origin.
    let reported = pose(turn(-75) * truth, at: SIMD3(0.1, 0.02, -0.05))
    let fix = SpotOrientation.realignment(expected: truth, position: place, reported: reported)
    XCTAssertEqual(SpotOrientation.yawDegrees(of: fix), 75, accuracy: 0.01)
    let fixed = fix * reported
    XCTAssertEqual(simd_distance(SIMD3(fixed.columns.3.x, fixed.columns.3.y, fixed.columns.3.z), place), 0, accuracy: 1e-4)
    XCTAssertEqual(simd_distance(SIMD3(fixed.columns.2.x, fixed.columns.2.y, fixed.columns.2.z), truth.columns.2), 0, accuracy: 1e-4)
    // A point one metre in front of the reported camera lands one metre in front of the true one.
    let ahead = fix * (reported * SIMD4(0, 0, -1, 1))
    XCTAssertEqual(simd_distance(SIMD3(ahead.x, ahead.y, ahead.z), place - truth.columns.2), 0, accuracy: 1e-4)
  }

  func testRealignmentOnlyTurnsAboutTheVertical() {
    // Sensor noise tips the expected rotation slightly; the fix must not tilt the world.
    let truth = turn(10)
    let noisy = simd_float3x3(simd_quatf(angle: 0.03, axis: SIMD3(1, 0, 0))) * truth
    let fix = SpotOrientation.realignment(
      expected: noisy, position: .zero, reported: pose(turn(-20) * truth, at: .zero))
    XCTAssertEqual(fix.columns.1.y, 1, accuracy: 1e-6)
    XCTAssertEqual(SpotOrientation.yawDegrees(of: fix), 20, accuracy: 0.5)
  }

  func testFacingFollowsThePersonWhateverThePhoneIsAimedAt() {
    // Upright and level, looking to −z.
    let level = simd_float3x3(SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1))
    let ahead = SIMD3<Float>(0, 0, -1)
    XCTAssertEqual(simd_distance(SpotOrientation.facing(cameraToWorld: level)!, ahead), 0, accuracy: 1e-5)
    // Tipped forward to the floor, then back to the ceiling: the person still faces −z.
    let floor = simd_float3x3(simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))) * level
    let ceiling = simd_float3x3(simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))) * level
    XCTAssertEqual(simd_distance(SpotOrientation.facing(cameraToWorld: floor)!, ahead), 0, accuracy: 1e-4)
    XCTAssertEqual(simd_distance(SpotOrientation.facing(cameraToWorld: ceiling)!, ahead), 0, accuracy: 1e-4)
  }

  func testThePhoneSwingsAroundThePersonAsTheyTurn() {
    let origin = SIMD3<Float>(1, 1.4, 1)
    // Facing −z at the start, +x at the end: the phone moved from in front to their right.
    let end = SpotOrientation.swung(
      from: origin, startFacing: SIMD3(0, 0, -1), facing: SIMD3(1, 0, 0), arm: 0.35)
    XCTAssertEqual(simd_distance(end, SIMD3(1.35, 1.4, 1.35)), 0, accuracy: 1e-5)
    XCTAssertEqual(
      SpotOrientation.swung(from: origin, startFacing: nil, facing: SIMD3(1, 0, 0), arm: 0.35), origin)
  }
}
