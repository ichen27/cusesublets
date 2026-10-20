import ARKit
import AVFoundation
import CoreImage
import CryptoKit
import ImageIO
import SceneKit
import SwiftUI

struct PhotoCaptureDraft: Codable {
  let id: String
  let ownerId: String
  let listingId: String
  var name: String
  static func folder(owner: String, listing: String) -> URL {
    let key = SHA256.hash(data: Data((owner + "/" + listing).utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("photo-captures", isDirectory: true).appendingPathComponent(
        key, isDirectory: true)
  }
}
final class PhotoRecorder: NSObject, ObservableObject, ARSessionDelegate {
  @Published var message = "Walk slowly around one room. Keep neighboring views overlapping."
  @Published var count = 0
  @Published var running = false
  @Published var saved = false
  @Published var packaging = false
  @Published var requestingPermission = false
  let view = ARSCNView(frame: .zero)
  let draft: PhotoCaptureDraft
  let folder: URL
  private let context = CIContext()
  private var policy = CapturePolicy()
  private var frames = [[String: Any]]()
  private var startTime: TimeInterval?
  private var permissionGeneration = UUID()
  private var observer: NSObjectProtocol?
  init(draft: PhotoCaptureDraft) {
    self.draft = draft
    folder = PhotoCaptureDraft.folder(owner: draft.ownerId, listing: draft.listingId)
    super.init()
    view.session.delegate = self
    view.session.delegateQueue = .main
    observer = NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.stop() }
  }
  deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
  func start() {
    guard !running, !packaging, !saved, !requestingPermission else { return }
    guard ARWorldTrackingConfiguration.isSupported else {
      message = "Photographic capture needs a supported iPhone camera."
      return
    }
    let generation = UUID()
    permissionGeneration = generation
    requestingPermission = true
    AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
      DispatchQueue.main.async {
        guard let self, self.permissionGeneration == generation else { return }
        self.requestingPermission = false
        guard UIApplication.shared.applicationState == .active else {
          self.message = "Return to the app and tap Start capture when ready."
          return
        }
        guard allowed else {
          self.message = "Enable camera access for CuseSublets in Settings."
          return
        }
        do {
          guard
            !FileManager.default.fileExists(
              atPath: self.folder.appendingPathComponent("draft.json").path)
          else {
            throw CaptureFailure.message(
              "A saved take already exists. Close this screen to recover it.")
          }
          try FileManager.default.createDirectory(
            at: self.folder.appendingPathComponent("images"), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
          try JSONEncoder().encode(self.draft).write(
            to: self.folder.appendingPathComponent("draft.json"),
            options: [.atomic, .completeFileProtection])
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          var directory = self.folder
          try directory.setResourceValues(values)
          let config = ARWorldTrackingConfiguration()
          config.worldAlignment = .gravity
          if let format = ARWorldTrackingConfiguration.supportedVideoFormats.filter({
            $0.imageResolution.width <= 1920 && $0.framesPerSecond == 30
          }).first {
            config.videoFormat = format
          }
          self.view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
          self.running = true
          UIApplication.shared.isIdleTimerDisabled = true
        } catch { self.message = error.localizedDescription }
      }
    }
  }
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard running else { return }
    if startTime == nil { startTime = frame.timestamp }
    let elapsed = frame.timestamp - (startTime ?? frame.timestamp)
    if elapsed >= 178 || count >= 180 {
      stop()
      return
    }
    var tracked = false
    if case .normal = frame.camera.trackingState { tracked = true }
    if let light = frame.lightEstimate, light.ambientIntensity < 150 {
      message = "Add more light before continuing."
      return
    }
    let pose = frame.camera.transform
    let decision = policy.evaluate(
      time: elapsed, position: SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z),
      forward: -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z), tracking: tracked)
    message = decision.message
    guard decision.save else { return }
    do {
      let source = CIImage(cvPixelBuffer: frame.capturedImage)
      let scale = min(1, 1280 / source.extent.width)
      let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      guard
        let jpeg = context.jpegRepresentation(
          of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
          options: [
            CIImageRepresentationOption(
              rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.75
          ]), jpeg.count < 1_000_000
      else { throw CaptureFailure.message("Camera frame could not be saved. Start a new take.") }
      let name = String(format: "images/%05d.jpg", frames.count)
      try jpeg.write(
        to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
      let k = frame.camera.intrinsics
      let matrix = (0..<4).map { row in (0..<4).map { column in Double(pose[column][row]) } }
      let sourcePoints = frame.rawFeaturePoints?.points ?? []
      let points = Swift.stride(
        from: 0, to: sourcePoints.count, by: max(1, sourcePoints.count / 250)
      ).prefix(250).map { i in
        [Double(sourcePoints[i].x), Double(sourcePoints[i].y), Double(sourcePoints[i].z)]
      }
      frames.append([
        "file_path": name, "timestamp": elapsed, "width": Int(image.extent.width.rounded()),
        "height": Int(image.extent.height.rounded()), "fx": Double(k[0][0]) * scale,
        "fy": Double(k[1][1]) * scale, "cx": Double(k[2][0]) * scale, "cy": Double(k[2][1]) * scale,
        "transform_matrix": matrix, "tracking": "normal", "points": points,
      ])
      try Self.writeManifest(frames, to: folder)
      count = frames.count
    } catch {
      message = error.localizedDescription
      stop()
    }
  }
  static func writeManifest(_ frames: [[String: Any]], to folder: URL) throws {
    let manifest: [String: Any] = [
      "schema_version": 1, "source": "arkit", "coordinate_system": "arkit-camera-to-world",
      "capability": "camera", "frames": frames,
    ]
    try JSONSerialization.data(withJSONObject: manifest).write(
      to: folder.appendingPathComponent("manifest.json"),
      options: [.atomic, .completeFileProtection])
  }
  static func package(folder: URL) throws -> URL {
    let manifest = folder.appendingPathComponent("manifest.json")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
    guard let frames = json?["frames"] as? [[String: Any]], frames.count >= 30 else {
      throw CaptureFailure.message(
        "This take has fewer than 30 stable views. Discard it and capture again.")
    }
    var entries = [("manifest.json", manifest)]
    for frame in frames {
      guard let name = frame["file_path"] as? String else {
        throw CaptureFailure.message("The saved take is incomplete.")
      }
      entries.append((name, folder.appendingPathComponent(name)))
    }
    let target = folder.appendingPathComponent("room.roomcapture")
    try CaptureArchive.write(entries: entries, to: target)
    return target
  }
  func stop() {
    permissionGeneration = UUID()
    if requestingPermission {
      requestingPermission = false
      message = "After answering the camera prompt, tap Start capture when ready."
    }
    guard running else { return }
    running = false
    view.session.pause()
    UIApplication.shared.isIdleTimerDisabled = false
    guard count >= 30 else {
      message =
        "Saved \(count) views. This take needs at least 30; close and discard it to try again."
      return
    }
    packaging = true
    let folder = self.folder
    Task {
      do {
        _ = try await Task.detached(priority: .userInitiated) { try Self.package(folder: folder) }
          .value
        await MainActor.run {
          self.saved = true
          self.packaging = false
          self.message = "Saved privately on this iPhone. Review the images before uploading."
        }
      } catch {
        await MainActor.run {
          self.packaging = false
          self.message = error.localizedDescription
        }
      }
    }
  }
  func sessionWasInterrupted(_ session: ARSession) { stop() }
  func session(_ session: ARSession, didFailWithError error: Error) {
    message = error.localizedDescription
    stop()
  }
}
struct PhotoCameraSurface: UIViewRepresentable {
  let recorder: PhotoRecorder
  func makeUIView(context: Context) -> ARSCNView { recorder.view }
  func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
struct PhotoCaptureScreen: View {
  @Environment(\.dismiss) var dismiss
  @StateObject var recorder: PhotoRecorder
  var body: some View {
    VStack(spacing: 16) {
      PhotoCameraSurface(recorder: recorder).ignoresSafeArea(edges: .top)
      Text(recorder.message).padding(.horizontal).accessibilityIdentifier("capture-guidance")
      Text("\(recorder.count) views · minimum 30 · aim for 60 or more").font(.caption)
      HStack {
        if recorder.running {
          Button("Finish capture") { recorder.stop() }.buttonStyle(.borderedProminent).tint(
            .cuseButtonFill)
        }
        if !recorder.running && !recorder.saved && recorder.count == 0 {
          Button("Start capture") { recorder.start() }
            .disabled(recorder.packaging || recorder.requestingPermission)
        }
        Button(recorder.saved ? "Review saved take" : "Close") {
          if recorder.running { recorder.stop() } else { dismiss() }
        }.disabled(recorder.packaging)
      }.padding(.bottom)
    }.task { recorder.start() }.onDisappear { recorder.stop() }.interactiveDismissDisabled(
      recorder.packaging)
  }
}
