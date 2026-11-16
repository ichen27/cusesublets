import SceneKit
import SwiftUI
import simd

/// A shot of the turn in progress, held where it was taken.
struct PinnedShot: Identifiable {
  let id: Int
  /// The picture, upright as the person saw it.
  let image: CGImage
  /// The phone's rotation in the world when it was taken (device frame: x right, y up).
  let rotation: simd_float3x3
  /// Tangents of half the picture's width and height as seen from the camera.
  let halfWidth: Float
  let halfHeight: Float
}

/// The space around the person while they turn at a spot: black where nothing has been taken
/// yet, with each shot staying where it was taken as the phone turns away from it.
struct SpotSpaceSurface: UIViewRepresentable {
  let shots: [PinnedShot]
  /// The phone's rotation in the world now (device frame).
  let rotation: simd_float3x3?
  /// Tangent of half the view across the screen. Matching the camera's makes a new shot land
  /// exactly where the person was looking.
  let halfWidth: Float

  func makeCoordinator() -> SpotSpace { SpotSpace() }
  func makeUIView(context: Context) -> SCNView { context.coordinator.view }
  func updateUIView(_ uiView: SCNView, context: Context) {
    context.coordinator.update(shots: shots, rotation: rotation, halfWidth: halfWidth)
  }
}

final class SpotSpace {
  /// Metres from the camera to each picture. Any distance looks the same from the centre.
  static let distance: Float = 10

  let view = SCNView(frame: .zero)
  private let eye = SCNNode()
  private var holders = [Int: SCNNode]()

  init() {
    let scene = SCNScene()
    scene.background.contents = UIColor.black
    let camera = SCNCamera()
    camera.zNear = 0.1
    camera.zFar = 100
    camera.projectionDirection = .horizontal
    eye.camera = camera
    scene.rootNode.addChildNode(eye)
    view.scene = scene
    view.pointOfView = eye
    view.backgroundColor = .black
    view.isUserInteractionEnabled = false
    view.antialiasingMode = .multisampling2X
  }

  func update(shots: [PinnedShot], rotation: simd_float3x3?, halfWidth: Float) {
    if let rotation { eye.simdOrientation = simd_quatf(rotation) }
    eye.camera?.fieldOfView = CGFloat(2 * atan(max(halfWidth, 0.1)) * 180 / .pi)
    let wanted = Set(shots.map(\.id))
    for (id, holder) in holders where !wanted.contains(id) {
      holder.removeFromParentNode()
      holders[id] = nil
    }
    for shot in shots where holders[shot.id] == nil {
      let holder = Self.holder(for: shot)
      view.scene?.rootNode.addChildNode(holder)
      holders[shot.id] = holder
    }
  }

  /// A node turned the way the phone was, carrying the picture straight ahead of it.
  static func holder(for shot: PinnedShot) -> SCNNode {
    let plane = SCNPlane(
      width: CGFloat(2 * distance * shot.halfWidth), height: CGFloat(2 * distance * shot.halfHeight))
    let material = SCNMaterial()
    material.diffuse.contents = shot.image
    material.lightingModel = .constant
    material.isDoubleSided = true
    // Pictures overlap; the newer one shows, whatever their depths.
    material.readsFromDepthBuffer = false
    material.writesToDepthBuffer = false
    plane.materials = [material]
    let picture = SCNNode(geometry: plane)
    picture.simdPosition = SIMD3(0, 0, -distance)
    picture.renderingOrder = shot.id
    let holder = SCNNode()
    holder.simdOrientation = simd_quatf(shot.rotation)
    holder.addChildNode(picture)
    return holder
  }
}
