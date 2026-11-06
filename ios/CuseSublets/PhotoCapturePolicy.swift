import Foundation
import simd

public struct CaptureDecision {
  public let save: Bool
  public let message: String
}

/// What the policy needs from one ARKit frame.
public struct CaptureSample {
  public var time: Double
  public var position: SIMD3<Float>
  /// Unit view direction in gravity-aligned world space (+y up).
  public var forward: SIMD3<Float>
  public var tracking: Bool
  /// Shutter time in seconds.
  public var exposure: Double
  /// Horizontal focal length in pixels of the saved image.
  public var focalLength: Float
  /// Median distance from the camera to tracked room features, when known.
  public var sceneDepth: Float?
  /// Tracked room features visible in this frame.
  public var featureCount: Int

  /// Median distance along the view axis to the points in front of the camera.
  public static func medianDepth(_ points: [SIMD3<Float>], camera transform: simd_float4x4)
    -> Float?
  {
    let inverse = transform.inverse
    let depths = points.compactMap { point -> Float? in
      let depth = -(inverse * SIMD4(point, 1)).z
      return depth > 0.1 ? depth : nil
    }.sorted()
    return depths.isEmpty ? nil : depths[depths.count / 2]
  }
}

/// Chooses which camera frames become views for reconstruction. A view is only useful if it is
/// sharp, sees trackable room features, and adds parallax: turning in place shows new surfaces but
/// gives reconstruction no depth, so it is allowed only briefly between real steps.
public struct CapturePolicy {
  /// Limits of the processing engine, which accepts 30–180 views within three minutes.
  public static let maximumViews = 180
  public static let maximumDuration = 178.0
  static let minimumInterval = 0.4
  static let maximumSpeed: Float = 0.6
  static let maximumTurnRate: Float = 0.9
  /// Image smear from camera motion during the exposure, in saved-image pixels.
  static let maximumBlur: Float = 4
  static let minimumFeatures = 40
  /// A sideways step of about 3.4° of parallax at the room's distance, within 6–20 cm.
  static let parallax: Float = 0.06
  static let minimumStep: Float = 0.06
  static let maximumStep: Float = 0.2
  static let turnAngle: Float = 0.26
  static let maximumTurnsInPlace = 2
  /// Views tilted more than 45° up see mostly blank ceiling.
  static let maximumUpwardTilt: Float = sin(.pi / 4)
  static let assumedDepth: Float = 1.5

  public private(set) var count = 0
  private var lastTime: Double?
  private var lastPosition = SIMD3<Float>.zero
  private var lastForward = SIMD3<Float>(0, 0, -1)
  private var turnsInPlace = 0
  private var observation: (time: Double, position: SIMD3<Float>, forward: SIMD3<Float>)?

  public init() {}

  /// `canSave` is false while the previous view is still being written; the frame is then
  /// skipped without being counted.
  public mutating func evaluate(_ sample: CaptureSample, canSave: Bool = true) -> CaptureDecision {
    guard sample.tracking else {
      observation = nil
      return .init(save: false, message: "Move slowly to establish tracking")
    }
    let previous = observation
    observation = (sample.time, sample.position, sample.forward)
    guard let previous, sample.time > previous.time else {
      return .init(save: false, message: "Hold steady")
    }
    let dt = Float(sample.time - previous.time)
    let speed = simd_distance(sample.position, previous.position) / dt
    let turnRate = Self.angle(sample.forward, previous.forward) / dt
    if speed > Self.maximumSpeed || turnRate > Self.maximumTurnRate {
      return .init(save: false, message: "Slow down")
    }
    if count >= Self.maximumViews || sample.time >= Self.maximumDuration {
      return .init(save: false, message: "Capture limit reached — finish this room")
    }
    if sample.forward.y > Self.maximumUpwardTilt {
      return .init(save: false, message: "Aim lower — capture walls and furniture, not the ceiling")
    }
    if sample.featureCount < Self.minimumFeatures {
      return .init(
        save: false, message: "Include furniture or edges — a blank wall cannot be tracked")
    }
    let depth = sample.sceneDepth ?? Self.assumedDepth
    let blur = (turnRate + speed / max(depth, 0.3)) * Float(sample.exposure) * sample.focalLength
    if blur > Self.maximumBlur {
      return .init(save: false, message: "Hold the phone steadier — this view is blurred")
    }
    var turnedInPlace = false
    if let lastTime {
      if sample.time - lastTime < Self.minimumInterval {
        return .init(save: false, message: "Keep moving slowly")
      }
      let step = min(max(Self.parallax * depth, Self.minimumStep), Self.maximumStep)
      if simd_distance(sample.position, lastPosition) < step {
        guard Self.angle(sample.forward, lastForward) >= Self.turnAngle else {
          return .init(save: false, message: "Move sideways for another view")
        }
        guard turnsInPlace < Self.maximumTurnsInPlace else {
          return .init(
            save: false, message: "Take a step sideways — turning in place adds no depth")
        }
        turnedInPlace = true
      }
    }
    guard canSave else { return .init(save: false, message: "Keep moving slowly") }
    count += 1
    turnsInPlace = turnedInPlace ? turnsInPlace + 1 : 0
    lastTime = sample.time
    lastPosition = sample.position
    lastForward = sample.forward
    return .init(save: true, message: "View saved — continue around the room")
  }

  private static func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    acos(max(-1, min(1, simd_dot(a, b))))
  }
}
