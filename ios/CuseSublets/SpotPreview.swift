import ImageIO
import SceneKit
import SwiftUI
import simd

/// A rough on-device 360 for one spot: each slice is a picture placed where the camera was
/// pointing, viewed from the middle. Not stitched; the server makes the clean panorama.
struct SpotPreview: UIViewRepresentable {
  let folder: URL
  let spot: SpotRecord
  let frames: [CaptureFrameRecord]

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> SCNView {
    let view = SCNView(frame: .zero)
    view.backgroundColor = .black
    let scene = SCNScene()
    let camera = SCNNode()
    camera.camera = SCNCamera()
    camera.camera?.fieldOfView = 70
    camera.camera?.zNear = 0.05
    scene.rootNode.addChildNode(camera)
    let records = Dictionary(frames.map { ($0.filePath, $0) }, uniquingKeysWith: { a, _ in a })
    for path in spot.slices {
      guard let record = records[path], let image = Self.image(folder.appendingPathComponent(path))
      else { continue }
      scene.rootNode.addChildNode(Self.node(for: record, image: image))
    }
    if let first = spot.slices.first.flatMap({ records[$0] }) {
      camera.simdOrientation = simd_quatf(Self.rotation(first))
    }
    view.scene = scene
    view.pointOfView = camera
    context.coordinator.camera = camera
    let pan = UIPanGestureRecognizer(
      target: context.coordinator, action: #selector(Coordinator.pan(_:)))
    view.addGestureRecognizer(pan)
    view.accessibilityLabel = "Rough 360 preview of spot \(spot.spot)"
    return view
  }

  func updateUIView(_ uiView: SCNView, context: Context) {}

  /// Camera-to-world rotation from the record's row-major transform.
  static func rotation(_ record: CaptureFrameRecord) -> simd_float3x3 {
    let m = record.transformMatrix
    return simd_float3x3(columns: (
      SIMD3(Float(m[0][0]), Float(m[1][0]), Float(m[2][0])),
      SIMD3(Float(m[0][1]), Float(m[1][1]), Float(m[2][1])),
      SIMD3(Float(m[0][2]), Float(m[1][2]), Float(m[2][2]))
    ))
  }

  /// A plane one metre in front of the slice's camera, sized to its field of view. The image
  /// is in sensor orientation, which matches the ARKit camera's own x/y axes.
  static func node(for record: CaptureFrameRecord, image: CGImage) -> SCNNode {
    let width = CGFloat(Double(record.width) / record.fx)
    let height = CGFloat(Double(record.height) / record.fy)
    let plane = SCNPlane(width: width, height: height)
    let material = SCNMaterial()
    material.diffuse.contents = image
    material.lightingModel = .constant
    material.isDoubleSided = true
    plane.materials = [material]
    let picture = SCNNode(geometry: plane)
    picture.simdPosition = SIMD3(0, 0, -1)
    let holder = SCNNode()
    holder.simdOrientation = simd_quatf(rotation(record))
    holder.addChildNode(picture)
    return holder
  }

  static func image(_ file: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 720,
      ] as CFDictionary)
  }

  final class Coordinator: NSObject {
    var camera: SCNNode?
    private var start: simd_quatf?

    @objc func pan(_ gesture: UIPanGestureRecognizer) {
      guard let camera, let view = gesture.view else { return }
      if gesture.state == .began { start = camera.simdOrientation }
      guard let start else { return }
      let t = gesture.translation(in: view)
      let yaw = simd_quatf(angle: Float(t.x / view.bounds.width) * .pi, axis: SIMD3(0, 1, 0))
      let pitch = simd_quatf(angle: Float(t.y / view.bounds.height) * .pi / 2, axis: SIMD3(1, 0, 0))
      camera.simdOrientation = yaw * start * pitch
    }
  }
}
