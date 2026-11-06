import Foundation
import simd

/// A problem the person capturing can fix. Normal capture shows no text: the coverage overlay is
/// the guidance, and the policy picks views silently.
public enum CaptureHint: Equatable {
  case establishTracking
  case addLight
  case slowDown
  case holdSteadier
  case findDetail
  case stepSideways
  case limitReached

  public var message: String {
    switch self {
    case .establishTracking: "Move slowly to establish tracking"
    case .addLight: "Add more light before continuing"
    case .slowDown: "Slow down"
    case .holdSteadier: "Hold steadier — the image is blurring"
    case .findDetail: "Aim at furniture or edges"
    case .stepSideways: "Take a step sideways — turning in place adds no depth"
    case .limitReached: "Capture limit reached — finish this room"
    }
  }

  /// How long a problem must last before it is shown, so brief moments do not flash text.
  var delay: Double {
    switch self {
    case .stepSideways: 1.5
    case .limitReached: 0
    default: 0.6
    }
  }
}

/// Why the policy saved or skipped a frame. Development streams record it to tune the rules.
public enum CaptureReason: String, Codable, CaseIterable {
  case saved
  case warmingUp
  case notTracking
  case dark
  case tooFast
  case limitReached
  case fewFeatures
  case blurred
  case tooSoon
  case noNewViewpoint
  case turnLimit
  case writerBusy

  /// Sharp and tracked enough to paint the coverage overlay, even if not saved.
  public var usable: Bool {
    switch self {
    case .saved, .tooSoon, .noNewViewpoint, .turnLimit, .writerBusy: true
    default: false
    }
  }

  public var hint: CaptureHint? {
    switch self {
    case .notTracking: .establishTracking
    case .dark: .addLight
    case .tooFast: .slowDown
    case .limitReached: .limitReached
    case .fewFeatures: .findDetail
    case .blurred: .holdSteadier
    case .turnLimit: .stepSideways
    default: nil
    }
  }
}

public struct CaptureDecision: Equatable {
  public let reason: CaptureReason
  /// Save this frame as a view.
  public var save: Bool { reason == .saved }
  public var usable: Bool { reason.usable }
  public var hint: CaptureHint? { reason.hint }
}

/// Motion measured between this frame and the previous one.
public struct CaptureMotion: Equatable {
  /// Metres per second.
  public let speed: Float
  /// Radians per second.
  public let turnRate: Float
  /// Distance to the room used for the blur and step estimates, in metres.
  public let depth: Float
  /// Expected smear from motion during the exposure, in saved-image pixels.
  public let blur: Float
}

/// Shows a hint only once it has lasted its delay, and keeps it up briefly after it clears.
public struct CaptureHintFilter {
  static let linger = 0.6
  private var pending: (hint: CaptureHint, since: Double)?
  private var lastSeen = -Double.infinity
  public private(set) var shown: CaptureHint?

  public init() {}

  public mutating func update(_ hint: CaptureHint?, at time: Double) -> CaptureHint? {
    if let hint {
      if pending?.hint != hint { pending = (hint, time) }
      if let pending, time - pending.since >= hint.delay {
        shown = hint
        lastSeen = time
      }
    } else {
      pending = nil
      if shown != nil, time - lastSeen >= Self.linger { shown = nil }
    }
    return shown
  }
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
/// gives reconstruction no depth, so it is saved only briefly between real steps. Frames that are
/// sharp but add nothing new are still `usable` for painting the coverage overlay.
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
  static let assumedDepth: Float = 1.5

  public private(set) var count = 0
  /// Motion of the last evaluated frame, when it could be measured.
  public private(set) var motion: CaptureMotion?
  private var lastTime: Double?
  private var lastPosition = SIMD3<Float>.zero
  private var lastForward = SIMD3<Float>(0, 0, -1)
  private var turnsInPlace = 0
  private var observation: (time: Double, position: SIMD3<Float>, forward: SIMD3<Float>)?

  public init() {}

  /// `canSave` is false while the previous view is still being written; the frame is then
  /// skipped without being counted.
  public mutating func evaluate(_ sample: CaptureSample, canSave: Bool = true) -> CaptureDecision {
    motion = nil
    guard sample.tracking else {
      observation = nil
      return .init(reason: .notTracking)
    }
    let previous = observation
    observation = (sample.time, sample.position, sample.forward)
    guard let previous, sample.time > previous.time else {
      return .init(reason: .warmingUp)
    }
    let dt = Float(sample.time - previous.time)
    let speed = simd_distance(sample.position, previous.position) / dt
    let turnRate = Self.angle(sample.forward, previous.forward) / dt
    let depth = sample.sceneDepth ?? Self.assumedDepth
    let blur = (turnRate + speed / max(depth, 0.3)) * Float(sample.exposure) * sample.focalLength
    motion = CaptureMotion(speed: speed, turnRate: turnRate, depth: depth, blur: blur)
    if speed > Self.maximumSpeed || turnRate > Self.maximumTurnRate {
      return .init(reason: .tooFast)
    }
    if count >= Self.maximumViews || sample.time >= Self.maximumDuration {
      return .init(reason: .limitReached)
    }
    if sample.featureCount < Self.minimumFeatures {
      return .init(reason: .fewFeatures)
    }
    if blur > Self.maximumBlur {
      return .init(reason: .blurred)
    }
    var turnedInPlace = false
    if let lastTime {
      if sample.time - lastTime < Self.minimumInterval {
        return .init(reason: .tooSoon)
      }
      let step = min(max(Self.parallax * depth, Self.minimumStep), Self.maximumStep)
      if simd_distance(sample.position, lastPosition) < step {
        guard Self.angle(sample.forward, lastForward) >= Self.turnAngle else {
          return .init(reason: .noNewViewpoint)
        }
        guard turnsInPlace < Self.maximumTurnsInPlace else {
          return .init(reason: .turnLimit)
        }
        turnedInPlace = true
      }
    }
    guard canSave else { return .init(reason: .writerBusy) }
    count += 1
    turnsInPlace = turnedInPlace ? turnsInPlace + 1 : 0
    lastTime = sample.time
    lastPosition = sample.position
    lastForward = sample.forward
    return .init(reason: .saved)
  }

  private static func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    acos(max(-1, min(1, simd_dot(a, b))))
  }
}
