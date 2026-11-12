import Foundation

enum SpotPhase: Equatable {
  /// Walking between spots, looking at the capture map.
  case map
  /// Turning in place at this spot number.
  case turning(spot: Int)
  /// Tracking was lost mid-turn; that spot was abandoned and the next waits for tracking.
  case relocating
  /// The ARKit session is over; finished spots remain for review and upload.
  case ended(reason: String)
}

/// The spot-capture flow as pure state, so its rules are testable without a camera.
struct SpotSession {
  static let endedMessage = "Capture ended. Your finished spots are saved."

  private(set) var phase = SpotPhase.map
  private(set) var completed: [Int]
  private var nextSpot: Int

  init(completed: [Int] = []) {
    self.completed = completed
    nextSpot = (completed.max() ?? 0) + 1
  }

  var canGenerate: Bool { !completed.isEmpty }

  /// Starts a turn if the take can hold a whole spot and tracking is normal.
  mutating func startSpot(budgetFits: Bool, tracking: Bool) -> Bool {
    guard phase == .map, tracking, budgetFits, completed.count < SpotTake.maximumSpots else {
      return false
    }
    phase = .turning(spot: nextSpot)
    nextSpot += 1
    return true
  }

  mutating func trackingChanged(normal: Bool) {
    switch phase {
    case .turning where !normal: phase = .relocating
    case .relocating where normal: phase = .map
    default: break
    }
  }

  mutating func spotFinished() {
    guard case .turning(let spot) = phase else { return }
    completed.append(spot)
    phase = .map
  }

  /// Gives up the current turn (its slices stay on disk for the mesh only).
  mutating func abandonSpot() {
    if case .turning = phase { phase = .map }
  }

  mutating func deleteSpot(_ spot: Int) { completed.removeAll { $0 == spot } }

  mutating func interrupted() { phase = .ended(reason: Self.endedMessage) }
}
