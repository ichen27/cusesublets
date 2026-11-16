import CoreGraphics
import ImageIO
import UIKit
import simd

/// One slice of a spot as the floor picture needs it: small RGBA pixels and where it looked.
struct FloorView {
  /// RGBA, row by row, `width * height * 4` bytes.
  let pixels: [UInt8]
  let width: Int
  let height: Int
  let fx: Float
  let fy: Float
  let cx: Float
  let cy: Float
  /// ARKit camera-to-world rotation (camera x right in the image, y up, z towards the viewer).
  let cameraToWorld: simd_float3x3
}

/// A picture of the room around a spot, seen from above, made on the phone from the spot's own
/// slices. It shows what a spot captured and where, on the map, before anything is uploaded.
///
/// With the depth model it is a `RoomSketch`: walls stop the picture, so it has the room's
/// shape. Without the model it falls back to `compose`, which treats everything as flat floor:
/// a round picture in which things standing on the floor are smeared outwards.
enum FloorPatch {
  /// Metres from the spot to the edge of its picture.
  static let radius: Float = RoomSketch.radius
  /// How far the flat-floor fallback reaches, and the share of that it stays opaque for.
  static let flatReach: Float = 2.5
  static let solidShare: Float = 0.6
  static let side = RoomSketch.side
  /// Slices are read at this width: about as sharp as the views the depth model is shown.
  static let thumbnail = 640
  /// A slice aimed below this (sine of −60°) is the floor shot.
  static let downward: Float = -0.866
  /// Floor distance towards the person, per metre of camera height, where the floor shot starts
  /// to be dropped and where it is dropped entirely. The same rule as the stitcher's.
  static let bodyStart: Float = 0.03
  static let bodyFull: Float = 0.09
  /// Weight of the other slices at which they fully replace the floor shot.
  static let levelFull: Float = 0.25

  static func url(folder: URL, spot: Int) -> URL {
    folder.appendingPathComponent("room", isDirectory: true).appendingPathComponent(
      String(format: "%02d.png", spot))
  }

  /// Slices prepared for sampling in any direction.
  struct Sampler {
    private let views: [(view: FloorView, worldToCamera: simd_float3x3, down: Bool, toward: SIMD2<Float>?)]

    init(_ views: [FloorView]) {
      self.views = views.map { view in
        let forward = -view.cameraToWorld.columns.2
        let x = view.cameraToWorld.columns.0
        let flat = SIMD2(x.x, x.z)
        return (
          view, view.cameraToWorld.transpose, forward.y < FloorPatch.downward,
          simd_length(flat) > 1e-4 ? simd_normalize(flat) : nil
        )
      }
    }

    /// The colour (0...255) the spot saw in a world direction, or nil where no slice looked or
    /// only the person holding the phone was in view. Slices taken with the person behind the
    /// camera win over the floor shot wherever they reach.
    func colour(_ direction: SIMD3<Float>) -> SIMD3<Float>? {
      // [0] slices taken with the person behind the camera, [1] the floor shot.
      var colour = [SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 0)]
      var weight: [Float] = [0, 0]
      for (view, worldToCamera, down, toward) in views {
        let c = worldToCamera * direction
        let depth = -c.z
        guard depth > 1e-4 else { continue }
        let u = view.fx * c.x / depth + view.cx
        let v = view.fy * -c.y / depth + view.cy
        guard u >= 0, v >= 0, u < Float(view.width), v < Float(view.height) else { continue }
        let edge = min(min(u, Float(view.width) - u), min(v, Float(view.height) - v))
        var w = min(1, edge / (Float(min(view.width, view.height)) / 2))
        w *= w
        if down, let toward, direction.y < 0 {
          let offset = (direction.x * toward.x + direction.z * toward.y) / -direction.y
          let t = simd_clamp(
            (offset - FloorPatch.bodyStart) / (FloorPatch.bodyFull - FloorPatch.bodyStart), 0, 1)
          w *= 1 - t * t * (3 - 2 * t)
        }
        guard w > 0 else { continue }
        let index = (Int(v) * view.width + Int(u)) * 4
        let sample = SIMD3(
          Float(view.pixels[index]), Float(view.pixels[index + 1]), Float(view.pixels[index + 2]))
        colour[down ? 1 : 0] += sample * w
        weight[down ? 1 : 0] += w
      }
      guard weight[0] + weight[1] > 1e-4 else { return nil }
      let level = colour[0] / max(weight[0], 1e-6)
      let floor = colour[1] / max(weight[1], 1e-6)
      let share = weight[1] > 1e-6 ? min(1, weight[0] / FloorPatch.levelFull) : 1
      return level * share + floor * (1 - share)
    }
  }

  /// The flat-floor fallback: RGBA pixels (`side * side * 4`) of the floor within `radius` of
  /// the camera, x to the right and z downwards as on the capture map, fading out at `reach`.
  /// `cameraHeight` is metres above the floor.
  static func compose(
    views: [FloorView], cameraHeight: Float, side: Int = side, radius: Float = radius,
    reach: Float = flatReach
  ) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: side * side * 4)
    guard cameraHeight > 0.2 else { return out }
    let sampler = Sampler(views)
    let reach = min(reach, radius)
    for row in 0..<side {
      for column in 0..<side {
        let x = ((Float(column) + 0.5) / Float(side) * 2 - 1) * radius
        let z = ((Float(row) + 0.5) / Float(side) * 2 - 1) * radius
        let distance = (x * x + z * z).squareRoot()
        guard distance < reach, let mixed = sampler.colour(SIMD3(x, -cameraHeight, z)) else {
          continue
        }
        let fade = simd_clamp((reach - distance) / (reach * (1 - solidShare)), 0, 1)
        let index = (row * side + column) * 4
        // Premultiplied alpha, as CGImage expects.
        out[index] = UInt8(simd_clamp(mixed.x * fade, 0, 255))
        out[index + 1] = UInt8(simd_clamp(mixed.y * fade, 0, 255))
        out[index + 2] = UInt8(simd_clamp(mixed.z * fade, 0, 255))
        out[index + 3] = UInt8(fade * 255)
      }
    }
    return out
  }

  /// Makes and saves a spot's floor picture from its slices on disk. Returns nil if a slice
  /// cannot be read.
  @discardableResult
  static func make(spot: SpotRecord, frames: [CaptureFrameRecord], folder: URL) -> UIImage? {
    let records = Dictionary(frames.map { ($0.filePath, $0) }, uniquingKeysWith: { _, last in last })
    var views = [FloorView]()
    for path in spot.slices {
      guard let record = records[path],
        let view = view(of: record, at: folder.appendingPathComponent(path))
      else { return nil }
      views.append(view)
    }
    let height = Float(spot.position[1] - spot.floorY)
    var pixels = [UInt8]()
    if let estimator = DepthEstimator.shared {
      let points = RoomSketch.points(slices: views, cameraHeight: height) { _, view in
        estimator.relativeDepth(rgba: view)
      }
      if points.count >= RoomSketch.minimumPoints {
        pixels = RoomSketch.picture(points: points, cameraHeight: height)
      }
    }
    if pixels.isEmpty { pixels = compose(views: views, cameraHeight: height) }
    guard let image = image(rgba: pixels, side: side) else { return nil }
    let target = url(folder: folder, spot: spot.spot)
    try? FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.complete])
    try? image.pngData()?.write(to: target, options: [.atomic, .completeFileProtection])
    return image
  }

  /// The saved floor pictures of these spots; a missing one is made now.
  static func load(folder: URL, spots: [SpotRecord], frames: [CaptureFrameRecord]) -> [Int: UIImage] {
    var pictures = [Int: UIImage]()
    for spot in spots {
      if let data = try? Data(contentsOf: url(folder: folder, spot: spot.spot)),
        let image = UIImage(data: data)
      {
        pictures[spot.spot] = image
      } else if let image = make(spot: spot, frames: frames, folder: folder) {
        pictures[spot.spot] = image
      }
    }
    return pictures
  }

  private static func view(of record: CaptureFrameRecord, at file: URL) -> FloorView? {
    guard record.transformMatrix.count >= 3, record.transformMatrix.allSatisfy({ $0.count >= 3 }),
      record.width > 0,
      let source = CGImageSourceCreateWithURL(file as CFURL, nil),
      let small = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: thumbnail,
          kCGImageSourceCreateThumbnailWithTransform: false,
        ] as CFDictionary)
    else { return nil }
    let width = small.width
    let height = small.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      context.draw(small, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    let scale = Float(width) / Float(record.width)
    let m = record.transformMatrix
    let rotation = simd_float3x3(
      SIMD3(Float(m[0][0]), Float(m[1][0]), Float(m[2][0])),
      SIMD3(Float(m[0][1]), Float(m[1][1]), Float(m[2][1])),
      SIMD3(Float(m[0][2]), Float(m[1][2]), Float(m[2][2])))
    return FloorView(
      pixels: pixels, width: width, height: height, fx: Float(record.fx) * scale,
      fy: Float(record.fy) * scale, cx: Float(record.cx) * scale, cy: Float(record.cy) * scale,
      cameraToWorld: rotation)
  }

  static func image(rgba: [UInt8], side: Int) -> UIImage? {
    guard rgba.count == side * side * 4, let provider = CGDataProvider(data: Data(rgba) as CFData),
      let image = CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    return UIImage(cgImage: image)
  }
}
