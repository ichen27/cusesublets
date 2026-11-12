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
}
