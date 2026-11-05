import Foundation
import simd

public struct CaptureDecision {
  public let save: Bool
  public let message: String
}
public struct CapturePolicy {
  public private(set) var count = 0
  private var lastTime: Double?
  private var lastPosition = SIMD3<Float>.zero
  private var lastForward = SIMD3<Float>(0, 0, -1)
  private var observation: (Double, SIMD3<Float>, SIMD3<Float>)?
  public init() {}
  public mutating func evaluate(
    time: Double, position: SIMD3<Float>, forward: SIMD3<Float>, tracking: Bool
  ) -> CaptureDecision {
    guard tracking else {
      observation = nil
      return .init(save: false, message: "Move slowly to establish tracking")
    }
    defer { observation = (time, position, forward) }
    if let (previous, p, f) = observation, time > previous {
      let dt = Float(time - previous)
      let angle = acos(max(-1, min(1, simd_dot(forward, f))))
      if simd_distance(position, p) / dt > 0.6 || angle / dt > 0.9 {
        return .init(save: false, message: "Slow down")
      }
    }
    if count >= 180 || time >= 178 {
      return .init(save: false, message: "Capture limit reached — finish this room")
    }
    if let lastTime {
      if time - lastTime < 0.65 { return .init(save: false, message: "Keep moving slowly") }
      let angle = acos(max(-1, min(1, simd_dot(forward, lastForward))))
      if simd_distance(position, lastPosition) < 0.08 && angle < 0.17 {
        return .init(save: false, message: "Move sideways for another view")
      }
    }
    count += 1
    lastTime = time
    lastPosition = position
    lastForward = forward
    return .init(save: true, message: "View saved — continue around the room")
  }
}
