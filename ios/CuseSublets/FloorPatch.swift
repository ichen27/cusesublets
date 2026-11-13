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

/// A picture of the floor around a spot, seen from above, made on the phone from the spot's own
/// slices. It shows what a spot captured and where, on the map, before anything is uploaded. Things
/// standing on the floor are smeared outwards, as in any top-down view made from one viewpoint.
enum FloorPatch {
  /// Metres from the spot to the edge of its picture.
  static let radius: Float = 2.5
  /// The picture is opaque out to this share of the radius, then fades to nothing.
  static let solidShare: Float = 0.6
  static let side = 192
  static let thumbnail = 320
  /// A slice aimed below this (sine of −60°) is the floor shot.
  static let downward: Float = -0.866
  /// Floor distance towards the person, per metre of camera height, where the floor shot starts
  /// to be dropped and where it is dropped entirely. The same rule as the stitcher's.
  static let bodyStart: Float = 0.03
  static let bodyFull: Float = 0.09
  /// Weight of the other slices at which they fully replace the floor shot.
  static let levelFull: Float = 0.25

  static func url(folder: URL, spot: Int) -> URL {
    folder.appendingPathComponent("floor", isDirectory: true).appendingPathComponent(
      String(format: "%02d.png", spot))
  }

  /// RGBA pixels (`side * side * 4`) of the floor within `radius` of the camera, x to the right
  /// and z downwards as on the capture map. `cameraHeight` is metres above the floor.
  static func compose(views: [FloorView], cameraHeight: Float, side: Int = side, radius: Float = radius)
    -> [UInt8]
  {
    var out = [UInt8](repeating: 0, count: side * side * 4)
    guard cameraHeight > 0.2 else { return out }
    let prepared = views.map { view -> (FloorView, simd_float3x3, Bool, SIMD2<Float>?) in
      let forward = -view.cameraToWorld.columns.2
      let x = view.cameraToWorld.columns.0
      let flat = SIMD2(x.x, x.z)
      let toward = simd_length(flat) > 1e-4 ? simd_normalize(flat) : nil
      return (view, view.cameraToWorld.transpose, forward.y < downward, toward)
    }
    for row in 0..<side {
      for column in 0..<side {
        let x = ((Float(column) + 0.5) / Float(side) * 2 - 1) * radius
        let z = ((Float(row) + 0.5) / Float(side) * 2 - 1) * radius
        let distance = (x * x + z * z).squareRoot()
        guard distance < radius else { continue }
        let direction = SIMD3(x, -cameraHeight, z)
        // [0] slices taken with the person behind the camera, [1] the floor shot.
        var colour = [SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 0)]
        var weight: [Float] = [0, 0]
        for (view, worldToCamera, down, toward) in prepared {
          let c = worldToCamera * direction
          let depth = -c.z
          guard depth > 1e-4 else { continue }
          let u = view.fx * c.x / depth + view.cx
          let v = view.fy * -c.y / depth + view.cy
          guard u >= 0, v >= 0, u < Float(view.width), v < Float(view.height) else { continue }
          let edge = min(min(u, Float(view.width) - u), min(v, Float(view.height) - v))
          var w = min(1, edge / (Float(min(view.width, view.height)) / 2))
          w *= w
          if down, let toward {
            let offset = (x * toward.x + z * toward.y) / cameraHeight
            let t = simd_clamp((offset - bodyStart) / (bodyFull - bodyStart), 0, 1)
            w *= 1 - t * t * (3 - 2 * t)
          }
          guard w > 0 else { continue }
          let index = (Int(v) * view.width + Int(u)) * 4
          let sample = SIMD3(
            Float(view.pixels[index]), Float(view.pixels[index + 1]), Float(view.pixels[index + 2]))
          colour[down ? 1 : 0] += sample * w
          weight[down ? 1 : 0] += w
        }
        guard weight[0] + weight[1] > 1e-5 else { continue }
        let level = colour[0] / max(weight[0], 1e-6)
        let floor = colour[1] / max(weight[1], 1e-6)
        let share = weight[1] > 1e-6 ? min(1, weight[0] / levelFull) : 1
        let mixed = level * share + floor * (1 - share)
        let fade = simd_clamp((radius - distance) / (radius * (1 - solidShare)), 0, 1)
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
    let pixels = compose(views: views, cameraHeight: height)
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
