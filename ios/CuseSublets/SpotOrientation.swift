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

  /// The horizontal direction the person holding the phone faces, from the camera's rotation.
  /// Level, that is where the camera looks. Aimed at the floor the top of the phone points
  /// away from them, and aimed at the ceiling it points back at them. Nil when undecided.
  static func facing(cameraToWorld: simd_float3x3) -> SIMD3<Float>? {
    let forward = -cameraToWorld.columns.2
    let top = -cameraToWorld.columns.0
    let flat = SIMD3(forward.x, 0, forward.z) + SIMD3(top.x, 0, top.z) * -forward.y
    return simd_length(flat) > 0.2 ? simd_normalize(flat) : nil
  }

  /// Where the phone is after a turn, given where it was when the turn began. The person pivots
  /// on the spot with the phone held out in front, so it swings on a circle around them.
  static func swung(
    from origin: SIMD3<Float>, startFacing: SIMD3<Float>?, facing: SIMD3<Float>?, arm: Float
  ) -> SIMD3<Float> {
    guard let startFacing, let facing else { return origin }
    return origin + (facing - startFacing) * arm
  }

  /// The correction for a tracking session restarted after a turn: it takes the poses the new
  /// session reports to the tour's world. The new session knows which way is up but not which
  /// way it faces or where it is, so the correction is a turn about the vertical through the
  /// phone plus a shift.
  /// - Parameters:
  ///   - expected: the camera's rotation in the tour's world, from the motion sensors.
  ///   - position: where the phone is in the tour's world.
  ///   - reported: the camera pose the restarted session reports for the same moment.
  static func realignment(
    expected: simd_float3x3, position: SIMD3<Float>, reported: simd_float4x4
  ) -> simd_float4x4 {
    let seen = simd_float3x3(
      SIMD3(reported.columns.0.x, reported.columns.0.y, reported.columns.0.z),
      SIMD3(reported.columns.1.x, reported.columns.1.y, reported.columns.1.z),
      SIMD3(reported.columns.2.x, reported.columns.2.y, reported.columns.2.z))
    let delta = expected * seen.transpose
    // The turn about +y that best matches `delta`.
    let yaw = atan2(delta[2][0] - delta[0][2], delta[0][0] + delta[2][2])
    let turn = simd_float3x3(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
    let here = SIMD3(reported.columns.3.x, reported.columns.3.y, reported.columns.3.z)
    let shift = position - turn * here
    return simd_float4x4(
      SIMD4(turn.columns.0, 0), SIMD4(turn.columns.1, 0), SIMD4(turn.columns.2, 0),
      SIMD4(shift, 1))
  }

  /// Degrees turned about the vertical by a correction from `realignment`.
  static func yawDegrees(of correction: simd_float4x4) -> Float {
    atan2(correction.columns.2.x, correction.columns.2.z) * 180 / .pi
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
