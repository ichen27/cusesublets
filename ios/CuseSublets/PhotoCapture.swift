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
  /// Per-view records, appended as views are saved; `manifest.json` is built from it at the end.
  static let recordsName = "frames.jsonl"
  /// Saved views keep the camera's full 1920-pixel width.
  static let savedWidth: CGFloat = 1920
  private let writer: CaptureWriter
  private var policy = CapturePolicy()
  private var startTime: TimeInterval?
  private var permissionGeneration = UUID()
  private var observer: NSObjectProtocol?
  init(draft: PhotoCaptureDraft) {
    self.draft = draft
    folder = PhotoCaptureDraft.folder(owner: draft.ownerId, listing: draft.listingId)
    writer = CaptureWriter(folder: folder)
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
          // The largest 4:3 format up to 1920 wide: 4:3 sees more floor and ceiling than 16:9.
          if let format = ARWorldTrackingConfiguration.supportedVideoFormats.filter({
            let size = $0.imageResolution
            return size.width <= Self.savedWidth && $0.framesPerSecond == 30
              && abs(size.width * 3 - size.height * 4) < 1
          }).max(by: { $0.imageResolution.width < $1.imageResolution.width }) {
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
    if elapsed >= CapturePolicy.maximumDuration || policy.count >= CapturePolicy.maximumViews {
      stop()
      return
    }
    var tracked = false
    if case .normal = frame.camera.trackingState { tracked = true }
    if let light = frame.lightEstimate, light.ambientIntensity < 150 {
      show("Add more light before continuing.")
      return
    }
    let pose = frame.camera.transform
    let points = frame.rawFeaturePoints?.points ?? []
    let source = CIImage(cvPixelBuffer: frame.capturedImage)
    let scale = min(1, Self.savedWidth / source.extent.width)
    let k = frame.camera.intrinsics
    let sample = CaptureSample(
      time: elapsed, position: SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z),
      forward: -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z), tracking: tracked,
      exposure: frame.camera.exposureDuration, focalLength: k[0][0] * Float(scale),
      sceneDepth: CaptureSample.medianDepth(points, camera: pose), featureCount: points.count)
    let decision = policy.evaluate(sample, canSave: !writer.busy)
    show(decision.message)
    guard decision.save else { return }
    let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let record = CaptureFrameRecord(
      filePath: "", timestamp: elapsed, width: Int(image.extent.width.rounded()),
      height: Int(image.extent.height.rounded()), fx: Double(k[0][0]) * Double(scale),
      fy: Double(k[1][1]) * Double(scale), cx: Double(k[2][0]) * Double(scale),
      cy: Double(k[2][1]) * Double(scale),
      transformMatrix: (0..<4).map { row in (0..<4).map { column in Double(pose[column][row]) } },
      points: CaptureFrameRecord.points(points))
    writer.save(image, record: record) { [weak self] outcome in
      guard let self else { return }
      switch outcome {
      case .saved(let count): self.count = count
      case .full:
        self.message = "This take has reached the 64 MB upload limit."
        self.stop()
      case .failed(let reason):
        self.message = reason
        self.stop()
      }
    }
  }
  /// Publishing the same text every frame would redraw the screen 60 times a second.
  private func show(_ text: String) { if message != text { message = text } }
  static func writeManifest(_ frames: [CaptureFrameRecord], to folder: URL) throws {
    try JSONEncoder().encode(CaptureManifest(frames: frames)).write(
      to: folder.appendingPathComponent("manifest.json"),
      options: [.atomic, .completeFileProtection])
  }
  /// The complete views of a take, in order. Reading stops at the first record that was cut off
  /// or whose image is missing, because processing requires consecutive image names.
  static func savedFrames(in folder: URL) throws -> [CaptureFrameRecord] {
    let records = folder.appendingPathComponent(recordsName)
    let manifest = folder.appendingPathComponent("manifest.json")
    if FileManager.default.fileExists(atPath: records.path) {
      var frames = [CaptureFrameRecord]()
      for line in try Data(contentsOf: records).split(separator: UInt8(ascii: "\n")) {
        let expected = String(format: "images/%05d.jpg", frames.count)
        guard let frame = try? JSONDecoder().decode(CaptureFrameRecord.self, from: Data(line)),
          frame.filePath == expected,
          FileManager.default.fileExists(atPath: folder.appendingPathComponent(expected).path)
        else { break }
        frames.append(frame)
      }
      return frames
    }
    // Takes saved before per-view records existed.
    guard FileManager.default.fileExists(atPath: manifest.path) else {
      throw CaptureFailure.message("This take has no stable views. Discard it and capture again.")
    }
    do {
      return try JSONDecoder().decode(CaptureManifest.self, from: Data(contentsOf: manifest)).frames
    } catch { throw CaptureFailure.message("The saved take is incomplete.") }
  }
  static func package(folder: URL) throws -> URL {
    let frames = try savedFrames(in: folder)
    guard frames.count >= 30 else {
      throw CaptureFailure.message(
        "This take has fewer than 30 stable views. Discard it and capture again.")
    }
    try writeManifest(frames, to: folder)
    let entries =
      [("manifest.json", folder.appendingPathComponent("manifest.json"))]
      + frames.map { ($0.filePath, folder.appendingPathComponent($0.filePath)) }
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
    packaging = true
    let folder = self.folder
    // Package only after the last view has finished writing.
    writer.afterPendingWrites { saved in
      let outcome = saved < 30 ? nil : Result { _ = try Self.package(folder: folder) }
      DispatchQueue.main.async {
        self.packaging = false
        self.count = saved
        switch outcome {
        case nil:
          self.message =
            "Saved \(saved) views. This take needs at least 30; close and discard it to try again."
        case .success:
          self.saved = true
          self.message = "Saved privately on this iPhone. Review the images before uploading."
        case .failure(let error): self.message = error.localizedDescription
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
