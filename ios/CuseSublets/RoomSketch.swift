import CoreML
import CoreVideo
import simd

/// A coloured point of the room, relative to where the spot's camera was (world axes, metres).
struct RoomPoint: Equatable {
  var position: SIMD3<Float>
  var colour: SIMD3<UInt8>
}

/// A rough 3D sketch of the room around a spot, drawn from above: the picture a person sees
/// on the map after each spot, so they can tell what has been captured and where.
///
/// The spot's slices are re-drawn as six upright views that look down into the room. A depth
/// model estimates relative depth in each, and the floor, whose distance is known from the
/// camera's height, turns that into metres. The points are then drawn from above with the
/// ceiling left off, so walls outline the room. It is a sketch, not a measurement: depth from
/// a single picture bends walls and misjudges clutter.
enum RoomSketch {
  /// The depth model's input size.
  static let width = 518
  static let height = 392
  /// 90° across.
  static let focal: Float = 259
  static let viewCount = 6
  /// Views look this far below level, so each sees floor to scale by and walls to outline.
  static let pitch: Float = -35 * .pi / 180
  /// Rays steeper than this (sine of 40° below level) probably hit the floor.
  static let floorSine: Float = 0.643
  /// Metres: nearer or farther estimates are dropped.
  static let nearest: Float = 0.3
  static let farthest: Float = 7
  /// The model blurs depth across object edges; pixels where inverse depth changes by more
  /// than this share between neighbours would hang in the air between surfaces.
  static let edgeTolerance: Float = 0.06
  /// A view's scale is trusted when this share of its floor-ward pixels agree on it.
  static let minimumAgreement: Float = 0.3
  static let agreementTolerance: Float = 0.05
  static let fitSamples = 4000
  static let fitRounds = 300
  /// Metres from the spot to the edge of the picture, and its size in pixels (4 cm each).
  static let radius: Float = 5
  static let side = 250
  /// Surfaces above this height over the floor are left off, so the ceiling does not hide the room.
  static let ceiling: Float = 1.9
  static let belowFloor: Float = 0.2
  /// Fewer points than this is not a picture worth showing.
  static let minimumPoints = 2000

  /// Camera-to-world rotation of an upright view (x right, y up, z towards the viewer). Yaw 0
  /// looks to −z and grows to the left, as ARKit's does.
  static func rotation(yaw: Float, pitch: Float) -> simd_float3x3 {
    let forward = SIMD3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
    let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
    return simd_float3x3(right, simd_cross(right, forward), -forward)
  }

  /// The ray through a view's pixel, in the view's camera frame, one metre deep.
  static func ray(column: Int, row: Int) -> SIMD3<Float> {
    SIMD3(
      (Float(column) + 0.5 - Float(width) / 2) / focal,
      -(Float(row) + 0.5 - Float(height) / 2) / focal, -1)
  }

  /// One view of the room re-drawn from the slices: RGBA pixels, and which of them a slice saw.
  static func render(_ rotation: simd_float3x3, from sampler: FloorPatch.Sampler)
    -> (pixels: [UInt8], seen: [Bool])
  {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    var seen = [Bool](repeating: false, count: width * height)
    for row in 0..<height {
      for column in 0..<width {
        let index = row * width + column
        guard let colour = sampler.colour(rotation * ray(column: column, row: row)) else {
          pixels[index * 4] = 0
          pixels[index * 4 + 1] = 0
          pixels[index * 4 + 2] = 0
          continue
        }
        pixels[index * 4] = UInt8(simd_clamp(colour.x, 0, 255))
        pixels[index * 4 + 1] = UInt8(simd_clamp(colour.y, 0, 255))
        pixels[index * 4 + 2] = UInt8(simd_clamp(colour.z, 0, 255))
        seen[index] = true
      }
    }
    return (pixels, seen)
  }

  /// Fits `expected ≈ a · prediction + b` when many pairs are wrong in one direction, as
  /// furniture is when the floor is expected: tries lines through random pairs and keeps the one
  /// most pairs agree with. Returns nil when too few agree.
  static func scale(prediction: [Float], expected: [Float]) -> (a: Float, b: Float, agreement: Float)? {
    let count = min(prediction.count, expected.count)
    guard count >= 50 else { return nil }
    // A fixed sequence, so the same spot always gives the same picture.
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(count))
    }
    func agreeing(_ a: Float, _ b: Float) -> [Int] {
      (0..<count).filter {
        abs(a * prediction[$0] + b - expected[$0]) < agreementTolerance * expected[$0]
      }
    }
    var best = [Int]()
    for _ in 0..<fitRounds {
      let i = next()
      let j = next()
      guard abs(prediction[i] - prediction[j]) > 1e-3 else { continue }
      let a = (expected[i] - expected[j]) / (prediction[i] - prediction[j])
      guard a > 0 else { continue }
      let inliers = agreeing(a, expected[i] - a * prediction[i])
      if inliers.count > best.count { best = inliers }
    }
    guard Float(best.count) >= minimumAgreement * Float(count) else { return nil }
    var sx: Float = 0
    var sy: Float = 0
    var sxx: Float = 0
    var sxy: Float = 0
    for index in best {
      sx += prediction[index]
      sy += expected[index]
      sxx += prediction[index] * prediction[index]
      sxy += prediction[index] * expected[index]
    }
    let n = Float(best.count)
    let determinant = n * sxx - sx * sx
    guard abs(determinant) > 1e-6 else { return nil }
    let a = (n * sxy - sx * sy) / determinant
    guard a > 0 else { return nil }
    return (a, (sy - a * sx) / n, n / Float(count))
  }

  private struct View {
    let rotation: simd_float3x3
    let pixels: [UInt8]
    let seen: [Bool]
    let relative: [Float]
    var line: (a: Float, b: Float)?
  }

  /// The room's points around a spot.
  /// - Parameters:
  ///   - cameraHeight: metres from the floor to the camera.
  ///   - depth: the model: relative inverse depth, `width * height` values, for view number
  ///     `index`'s RGBA pixels, or nil if it cannot run.
  static func points(
    slices: [FloorView], cameraHeight: Float, depth: (_ index: Int, _ pixels: [UInt8]) -> [Float]?
  ) -> [RoomPoint] {
    guard cameraHeight > 0.2 else { return [] }
    let sampler = FloorPatch.Sampler(slices)
    var views = [View]()
    for index in 0..<viewCount {
      let rotation = rotation(yaw: 2 * .pi * Float(index) / Float(viewCount), pitch: pitch)
      let drawn = render(rotation, from: sampler)
      guard let relative = depth(index, drawn.pixels), relative.count == width * height else {
        return []
      }
      views.append(View(rotation: rotation, pixels: drawn.pixels, seen: drawn.seen, relative: relative))
    }
    let step = max(1, width * height / fitSamples)
    // First the views that see enough floor to scale themselves.
    for index in views.indices {
      var prediction = [Float]()
      var expected = [Float]()
      let view = views[index]
      for pixel in stride(from: 0, to: width * height, by: step) where view.seen[pixel] {
        let world = view.rotation * ray(column: pixel % width, row: pixel / width)
        guard world.y / simd_length(world) < -floorSine, view.relative[pixel].isFinite else {
          continue
        }
        prediction.append(view.relative[pixel])
        expected.append(-world.y / cameraHeight)
      }
      if let line = scale(prediction: prediction, expected: expected) {
        views[index].line = (line.a, line.b)
      }
    }
    // Then the rest, from what their scaled neighbours say about the directions they share.
    for index in views.indices where views[index].line == nil {
      var prediction = [Float]()
      var expected = [Float]()
      let view = views[index]
      for offset in [1, viewCount - 1] {
        let other = views[(index + offset) % viewCount]
        guard let line = other.line else { continue }
        for pixel in stride(from: 0, to: width * height, by: step) where view.seen[pixel] {
          let mine = ray(column: pixel % width, row: pixel / width)
          let theirs = other.rotation.transpose * (view.rotation * mine)
          guard -theirs.z > 1e-3, view.relative[pixel].isFinite else { continue }
          let column = Int(focal * theirs.x / -theirs.z + Float(width) / 2)
          let row = Int(-focal * theirs.y / -theirs.z + Float(height) / 2)
          guard column >= 0, row >= 0, column < width, row < height else { continue }
          let there = row * width + column
          let inverse = line.a * other.relative[there] + line.b
          guard other.seen[there], inverse > 1 / farthest, inverse < 1 / nearest else { continue }
          // Same distance along the shared direction; each view measures depth along its own axis.
          prediction.append(view.relative[pixel])
          expected.append(inverse * -theirs.z)
        }
      }
      if let line = scale(prediction: prediction, expected: expected) {
        views[index].line = (line.a, line.b)
      }
    }
    var points = [RoomPoint]()
    for view in views {
      guard let line = view.line else { continue }
      func inverse(_ column: Int, _ row: Int) -> Float {
        line.a * view.relative[row * width + column] + line.b
      }
      for row in 1..<(height - 1) {
        for column in 1..<(width - 1) {
          let pixel = row * width + column
          guard view.seen[pixel] else { continue }
          let centre = inverse(column, row)
          guard centre > 1 / farthest, centre < 1 / nearest else { continue }
          let change =
            abs(inverse(column + 1, row) - inverse(column - 1, row)) / 2
            + abs(inverse(column, row + 1) - inverse(column, row - 1)) / 2
          guard change < edgeTolerance * centre else { continue }
          let position = view.rotation * ray(column: column, row: row) / centre
          points.append(
            RoomPoint(
              position: position,
              colour: SIMD3(view.pixels[pixel * 4], view.pixels[pixel * 4 + 1], view.pixels[pixel * 4 + 2])))
        }
      }
    }
    return points
  }

  /// The points seen from above: RGBA pixels (`side * side * 4`, premultiplied), x to the right
  /// and z downwards as on the capture map, the spot in the middle. In each cell the highest
  /// surface below the ceiling shows.
  static func picture(
    points: [RoomPoint], cameraHeight: Float, side: Int = side, radius: Float = radius
  ) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: side * side * 4)
    var top = [Float](repeating: -.infinity, count: side * side)
    for point in points {
      let above = point.position.y + cameraHeight
      guard above > -belowFloor, above < ceiling else { continue }
      let column = Int(((point.position.x / radius + 1) / 2 * Float(side)).rounded(.down))
      let row = Int(((point.position.z / radius + 1) / 2 * Float(side)).rounded(.down))
      guard column >= 0, row >= 0, column < side, row < side else { continue }
      let cell = row * side + column
      guard above > top[cell] else { continue }
      top[cell] = above
      out[cell * 4] = point.colour.x
      out[cell * 4 + 1] = point.colour.y
      out[cell * 4 + 2] = point.colour.z
      out[cell * 4 + 3] = 255
    }
    return out
  }
}

/// The bundled depth model, for pictures made away from the live camera.
final class DepthEstimator {
  /// Nil when the model is not in this build or cannot load.
  static let shared = DepthEstimator()

  private let model: MLModel
  private let lock = NSLock()

  private init?() {
    guard
      let url = Bundle.main.url(
        forResource: CaptureCoverageEngine.modelName, withExtension: "mlmodelc")
    else { return nil }
    let configuration = MLModelConfiguration()
    #if targetEnvironment(simulator)
      // The simulator's GPU path returns zeros for this half-float model.
      configuration.computeUnits = .cpuOnly
    #else
      configuration.computeUnits = .all
    #endif
    guard let model = try? MLModel(contentsOf: url, configuration: configuration) else { return nil }
    self.model = model
  }

  /// Relative inverse depth for an RGBA picture of the model's input size.
  func relativeDepth(rgba: [UInt8]) -> [Float]? {
    let width = CaptureCoverageEngine.inputWidth
    let height = CaptureCoverageEngine.inputHeight
    guard rgba.count == width * height * 4 else { return nil }
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard
      CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        == kCVReturnSuccess, let buffer
    else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
      let stride = CVPixelBufferGetBytesPerRow(buffer)
      let target = base.assumingMemoryBound(to: UInt8.self)
      for row in 0..<height {
        for column in 0..<width {
          let from = (row * width + column) * 4
          let to = row * stride + column * 4
          target[to] = rgba[from + 2]
          target[to + 1] = rgba[from + 1]
          target[to + 2] = rgba[from]
          target[to + 3] = 255
        }
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    lock.lock()
    defer { lock.unlock() }
    guard
      let output = try? model.prediction(
        from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])),
      let image = output.featureValue(for: "depth")?.imageBufferValue,
      let depth = CaptureCoverageEngine.relativeDepth(image), depth.width == width,
      depth.height == height
    else { return nil }
    return depth.values
  }
}
