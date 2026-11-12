import CoreMotion
import simd

/// Turns motion-sensor attitudes into camera rotations in the tour's ARKit world, for the
/// part of a spot where ARKit is paused and the 0.5× camera is running.
///
/// Three frames are involved. *Device*: x right, y towards the top of the phone, z out of the
/// screen. *Camera* (ARKit's convention, matching the sensor image): x towards the bottom of
/// the phone, y towards its right edge, z out of the screen. *World*: ARKit's gravity-aligned
/// world, y up.
struct SpotOrientation {
  /// Camera coordinates of a device-frame vector.
  static let cameraFromDevice = simd_float3x3(rows: [
    SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1),
  ])

  /// World-from-reference: fixed for the turn, solved when the spot starts.
  private let worldFromReference: simd_float3x3
  /// Degrees between gravity as ARKit and as the motion sensors saw it when the spot started.
  /// Large values mean the frames above do not describe this device.
  let gravityMismatchDegrees: Float

  /// - Parameters:
  ///   - cameraToWorld: ARKit camera rotation at the moment the spot starts.
  ///   - deviceToReference: motion attitude at the same moment (see `deviceToReference`).
  init(cameraToWorld: simd_float3x3, deviceToReference: simd_float3x3) {
    let worldFromDevice = cameraToWorld * Self.cameraFromDevice
    worldFromReference = worldFromDevice * deviceToReference.transpose
    // The reference frame's z axis is vertical, so its image in the world should be +y.
    let up = simd_normalize(worldFromReference * SIMD3<Float>(0, 0, 1))
    gravityMismatchDegrees = acos(simd_clamp(up.y, -1, 1)) * 180 / .pi
  }

  func worldFromDevice(_ deviceToReference: simd_float3x3) -> simd_float3x3 {
    worldFromReference * deviceToReference
  }

  /// ARKit-style camera-to-world rotation for a slice.
  func cameraToWorld(_ deviceToReference: simd_float3x3) -> simd_float3x3 {
    worldFromDevice(deviceToReference) * Self.cameraFromDevice.transpose
  }

  /// The direction the back camera faces, in world coordinates.
  func forward(_ deviceToReference: simd_float3x3) -> SIMD3<Float> {
    worldFromDevice(deviceToReference) * SIMD3<Float>(0, 0, -1)
  }

  /// The device-to-reference rotation of a motion sample. Core Motion documents its rotation
  /// matrix loosely, so the direction is settled with the sample's own gravity reading: the
  /// reference frame's down, taken into the device frame, must equal measured gravity.
  static func deviceToReference(_ motion: CMDeviceMotion) -> simd_float3x3 {
    let m = motion.attitude.rotationMatrix
    let matrix = simd_float3x3(rows: [
      SIMD3(Float(m.m11), Float(m.m12), Float(m.m13)),
      SIMD3(Float(m.m21), Float(m.m22), Float(m.m23)),
      SIMD3(Float(m.m31), Float(m.m32), Float(m.m33)),
    ])
    let gravity = SIMD3(Float(motion.gravity.x), Float(motion.gravity.y), Float(motion.gravity.z))
    return deviceToReference(matrix: matrix, gravity: gravity)
  }

  static func deviceToReference(matrix: simd_float3x3, gravity: SIMD3<Float>) -> simd_float3x3 {
    let down = SIMD3<Float>(0, 0, -1)
    let asReferenceToDevice = simd_dot(matrix * down, gravity)
    let asDeviceToReference = simd_dot(matrix.transpose * down, gravity)
    return asReferenceToDevice >= asDeviceToReference ? matrix.transpose : matrix
  }

  /// Where a world direction appears on a portrait screen showing the camera aspect-filled.
  /// - Parameters:
  ///   - focal: focal length in sensor-image pixels.
  ///   - image: sensor image size (landscape: width is the long side).
  /// - Returns: the point, and whether the direction is in front of the camera.
  func screenPoint(
    of direction: SIMD3<Float>, deviceToReference: simd_float3x3, focal: Float, image: CGSize,
    screen: CGSize
  ) -> (point: CGPoint, ahead: Bool) {
    let d = worldFromDevice(deviceToReference).transpose * direction
    let scale = max(screen.width / image.height, screen.height / image.width) * CGFloat(focal)
    let depth = max(abs(-d.z), 0.05)
    let point = CGPoint(
      x: screen.width / 2 + scale * CGFloat(d.x / depth),
      y: screen.height / 2 - scale * CGFloat(d.y / depth))
    return (point, -d.z > 0.2)
  }
}
