import ARKit
import Accelerate
import CoreImage
import CoreML
import SceneKit

/// Estimates depth for saved views off the main thread and draws the coverage overlay.
/// Depth maps and the coverage map stay in memory; nothing here is written to the take.
final class CaptureCoverageEngine {
  static let modelName = "DepthAnythingV2SmallF16P6"
  static let inputWidth = 518
  static let inputHeight = 392

  /// Main-thread callback with the share of seen surfaces that are covered (0...1),
  /// or nil when the depth model is unavailable on this device.
  var onUpdate: ((Double?) -> Void)?
  /// Main-thread callback with the top-down capture map and the floor height it was built for,
  /// after each view that updated the map.
  var onMap: (([TopDownCell], Float) -> Void)?

  private let queue = DispatchQueue(label: "com.ichen27.cusesublets.coverage", qos: .utility)
  private let context = CIContext()
  private let overlay = CoverageOverlay()
  // Main thread only.
  private var busy = false
  private var generation = 0
  private var unavailable = false
  // Coverage queue only.
  private var model: MLModel?
  private var map = CoverageMap()
  private var floorPlanes = [Float]()

  /// Heights of horizontal ARKit planes; the lowest is taken as the floor.
  func setFloorPlanes(_ heights: [Float]) {
    queue.async { self.floorPlanes = heights }
  }

  func reset(view: ARSCNView) {
    generation += 1
    busy = false
    overlay.clear()
    overlay.attach(to: view)
    queue.async {
      self.map = CoverageMap()
      self.floorPlanes = []
      _ = self.loadModel()
    }
  }

  /// Hides the live overlay without clearing the map, e.g. while turning at a spot.
  func setOverlayHidden(_ hidden: Bool) { overlay.setHidden(hidden) }

  /// Call once per frame while capturing; the camera-attached tint needs the AR camera node.
  func frameDidUpdate(view: ARSCNView) { overlay.attach(to: view) }

  /// Call on the main thread for a view that was just saved. Skips the view if the previous
  /// estimate is still running so capture never waits on the model.
  func submit(_ frame: ARFrame) {
    guard !busy, !unavailable else { return }
    let image = frame.capturedImage
    let sx = Float(Self.inputWidth) / Float(CVPixelBufferGetWidth(image))
    let sy = Float(Self.inputHeight) / Float(CVPixelBufferGetHeight(image))
    guard let input = makeInput(image, sx: CGFloat(sx), sy: CGFloat(sy)) else { return }
    let k = frame.camera.intrinsics
    let camera = CoverageCamera(
      fx: k[0][0] * sx, fy: k[1][1] * sy, cx: k[2][0] * sx, cy: k[2][1] * sy,
      transform: frame.camera.transform)
    let points = frame.rawFeaturePoints?.points ?? []
    busy = true
    let generation = generation
    queue.async {
      let result = self.estimate(input: input, camera: camera, points: points)
      DispatchQueue.main.async {
        guard generation == self.generation else { return }
        self.busy = false
        switch result {
        case .unavailable:
          self.unavailable = true
          self.overlay.clear()
          self.onUpdate?(nil)
        case .skipped: break
        case .updated(let points, let fraction, let top):
          self.overlay.update(points)
          self.onUpdate?(fraction)
          if let top { self.onMap?(top.cells, top.floorY) }
        }
      }
    }
  }

  private enum Estimate {
    case unavailable
    case skipped
    case updated([CoveragePoint], Double, (cells: [TopDownCell], floorY: Float)?)
  }

  private func estimate(input: CVPixelBuffer, camera: CoverageCamera, points: [SIMD3<Float>])
    -> Estimate
  {
    guard let model = loadModel() else { return .unavailable }
    guard
      let output = try? model.prediction(
        from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
      ), let buffer = output.featureValue(for: "depth")?.imageBufferValue,
      let depth = Self.relativeDepth(buffer)
    else { return .skipped }
    let colors = Self.colorSampler(input, depthWidth: depth.width, depthHeight: depth.height)
    guard map.integrate(depth: depth, camera: camera, trackedPoints: points, colors: colors) else {
      return .skipped
    }
    let snapshot = map.snapshot()
    let centers = map.cells.keys.map { (SIMD3<Float>($0) + 0.5) * CoverageMap.voxelSize }
    let top = FloorCoverage.estimateFloorY(planes: floorPlanes, cells: centers).map {
      (cells: map.topDown(floorY: $0), floorY: $0)
    }
    return .updated(snapshot.points, snapshot.coveredFraction, top)
  }

  private func loadModel() -> MLModel? {
    if let model { return model }
    guard let url = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") else {
      return nil
    }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    model = try? MLModel(contentsOf: url, configuration: configuration)
    return model
  }

  private func makeInput(_ image: CVPixelBuffer, sx: CGFloat, sy: CGFloat) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    guard
      CVPixelBufferCreate(
        nil, Self.inputWidth, Self.inputHeight, kCVPixelFormatType_32BGRA, attributes, &buffer)
        == kCVReturnSuccess, let buffer
    else { return nil }
    let scaled = CIImage(cvPixelBuffer: image).transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    context.render(scaled, to: buffer)
    return buffer
  }

  /// Reads the model's BGRA input once and returns colours (0...1) at depth-map pixels.
  static func colorSampler(_ buffer: CVPixelBuffer, depthWidth: Int, depthHeight: Int)
    -> ((Int, Int) -> SIMD3<Float>)?
  {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer), depthWidth > 0, depthHeight > 0 else {
      return nil
    }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let row = CVPixelBufferGetBytesPerRow(buffer)
    let bytes = [UInt8](UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: row * height))
    return { x, y in
      let px = min(width - 1, x * width / depthWidth)
      let py = min(height - 1, y * height / depthHeight)
      let offset = py * row + px * 4
      return SIMD3(Float(bytes[offset + 2]), Float(bytes[offset + 1]), Float(bytes[offset])) / 255
    }
  }

  /// Converts the model's half-float grayscale image (with any row padding) to floats.
  static func relativeDepth(_ buffer: CVPixelBuffer) -> RelativeDepthMap? {
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent16Half else {
      return nil
    }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    var values = [Float](repeating: 0, count: width * height)
    let status = values.withUnsafeMutableBytes { target -> vImage_Error in
      var source = vImage_Buffer(
        data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
        rowBytes: CVPixelBufferGetBytesPerRow(buffer))
      var destination = vImage_Buffer(
        data: target.baseAddress, height: vImagePixelCount(height),
        width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
      return vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)
    }
    guard status == kvImageNoError else { return nil }
    return RelativeDepthMap(width: width, height: height, values: values)
  }
}

/// Seen surfaces drawn as small squares coloured by coverage, over a blue tint that marks
/// everything not yet seen. The tint sits behind the squares, so the depth test hides it
/// wherever a surface has been captured.
final class CoverageOverlay {
  static let colors: [(red: CGFloat, green: CGFloat, blue: CGFloat, opacity: CGFloat)] = [
    (1, 0.6, 0.1, 0.6),  // seen from one direction
    (1, 0.88, 0.45, 0.45),  // two directions
    (1, 1, 1, 0.18),  // covered
  ]
  private let surfaces = SCNNode()
  private let tint: SCNNode

  init() {
    let plane = SCNPlane(width: 60, height: 60)
    let material = SCNMaterial()
    material.lightingModel = .constant
    material.diffuse.contents = UIColor(red: 0.2, green: 0.32, blue: 0.95, alpha: 1)
    material.transparency = 0.38
    material.writesToDepthBuffer = false
    material.readsFromDepthBuffer = true
    material.isDoubleSided = true
    plane.materials = [material]
    tint = SCNNode(geometry: plane)
    tint.position = SCNVector3(0, 0, -(CoverageMap.farthest + 3))
    tint.renderingOrder = 100
    surfaces.renderingOrder = 0
  }

  func attach(to view: ARSCNView) {
    if surfaces.parent == nil { view.scene.rootNode.addChildNode(surfaces) }
    if tint.parent == nil, let camera = view.pointOfView { camera.addChildNode(tint) }
  }

  func clear() { surfaces.geometry = nil }

  func setHidden(_ hidden: Bool) {
    surfaces.isHidden = hidden
    tint.isHidden = hidden
  }

  func update(_ points: [CoveragePoint]) {
    guard !points.isEmpty else {
      clear()
      return
    }
    let vertices = points.map { SCNVector3($0.center.x, $0.center.y, $0.center.z) }
    var elements = [SCNGeometryElement]()
    var materials = [SCNMaterial]()
    for (index, color) in Self.colors.enumerated() {
      let level = index + 1
      let indices = points.indices.filter { min(points[$0].level, Self.colors.count) == level }
        .map { UInt32($0) }
      guard !indices.isEmpty else { continue }
      let element = SCNGeometryElement(indices: indices, primitiveType: .point)
      element.pointSize = CGFloat(CoverageMap.voxelSize) * 1.1
      element.minimumPointScreenSpaceRadius = 1.5
      element.maximumPointScreenSpaceRadius = 40
      elements.append(element)
      let material = SCNMaterial()
      material.lightingModel = .constant
      material.diffuse.contents = UIColor(
        red: color.red, green: color.green, blue: color.blue, alpha: 1)
      material.transparency = color.opacity
      material.writesToDepthBuffer = true
      material.readsFromDepthBuffer = true
      materials.append(material)
    }
    let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)], elements: elements)
    geometry.materials = materials
    surfaces.geometry = geometry
  }
}
