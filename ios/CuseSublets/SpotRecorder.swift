import ARKit
import AVFoundation
import CoreImage
import SwiftUI

/// Records a spot tour in one ARKit session: walk frames on the capture map, guided slices
/// while turning at a spot. Rules live in `SpotSession`, `SpotTurn` and `SpotTake`; this class
/// connects them to the camera.
final class SpotRecorder: NSObject, ObservableObject, ARSessionDelegate {
  /// Conservative size of one 1440 × 1080 slice, for deciding whether a whole spot still fits.
  static let estimatedSliceBytes = 350_000
  static let walkWidth: CGFloat = 1920
  /// Used when no floor has been seen yet: typical phone height above the floor.
  static let assumedEyeHeight = 1.45

  @Published private(set) var phase = SpotPhase.map
  @Published private(set) var turn: SpotTurn?
  @Published private(set) var spots: [SpotRecord] = []
  @Published private(set) var mapCells: [TopDownCell] = []
  @Published private(set) var coverage: Double = 0
  @Published private(set) var hint: CaptureHint?
  @Published private(set) var you: SIMD2<Float>?
  @Published private(set) var running = false
  @Published private(set) var requestingPermission = false
  @Published var message = ""

  let view = ARSCNView(frame: .zero)
  let draft: PhotoCaptureDraft
  let folder: URL
  var canGenerate: Bool { session.canGenerate }
  var spotsRemaining: Int { SpotTake.maximumSpots - session.completed.count }

  private var session: SpotSession
  private let writer: CaptureWriter
  private let coverageEngine = CaptureCoverageEngine()
  private var walkPolicy = CapturePolicy(
    maximumViews: SpotTake.maximumWalkFrames, maximumDuration: .infinity)
  /// Measures motion while turning; its save decisions are ignored.
  private var steadiness = CapturePolicy(maximumViews: .max, maximumDuration: .infinity)
  private var hints = CaptureHintFilter()
  private var lastPaint = -Double.infinity
  private var startTime: TimeInterval?
  private var floorY: Float?
  private var planes = [UUID: Float]()
  private var permissionGeneration = UUID()
  private var observer: NSObjectProtocol?
  // The spot being turned.
  private var slicePaths = [String]()
  private var slicePositions = [SIMD3<Float>]()
  private var pendingSlices = 0
  private var finishing = false
  private var lockedExposure: (duration: Double, iso: Double) = (0, 0)

  init(draft: PhotoCaptureDraft) {
    self.draft = draft
    folder = SpotTake.folder(owner: draft.ownerId, listing: draft.listingId)
    writer = CaptureWriter(
      folder: folder,
      budget: CaptureBudget(maximumViews: SpotTake.maximumViews, archiveLimit: SpotTake.archiveLimit))
    let frames = (try? PhotoRecorder.savedFrames(in: folder)) ?? []
    let saved = SpotTake.savedSpots(in: folder, frames: frames)
    session = SpotSession(completed: saved.map(\.spot))
    super.init()
    spots = saved
    view.session.delegate = self
    view.session.delegateQueue = .main
    coverageEngine.onMap = { [weak self] cells, floor in
      guard let self else { return }
      self.floorY = floor
      self.mapCells = cells
      self.refreshCoverage()
    }
    observer = NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.end() }
  }
  deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

  /// A take already on disk can be reviewed and uploaded but not extended: its tracking origin
  /// is gone.
  var hasSavedTake: Bool {
    FileManager.default.fileExists(atPath: folder.appendingPathComponent("draft.json").path)
  }

  func start() {
    guard !running, !requestingPermission else { return }
    guard !hasSavedTake else {
      session.interrupted()
      phase = session.phase
      message = "A saved take was recovered. Review its spots, then generate the tour."
      return
    }
    guard ARWorldTrackingConfiguration.isSupported else {
      message = "Spot capture needs a supported iPhone camera."
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
          self.message = "Return to the app to start capturing."
          return
        }
        guard allowed else {
          self.message = "Enable camera access for CuseSublets in Settings."
          return
        }
        do { try self.run() } catch { self.message = error.localizedDescription }
      }
    }
  }

  private func run() throws {
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent("images"), withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.complete])
    try JSONEncoder().encode(draft).write(
      to: folder.appendingPathComponent("draft.json"), options: [.atomic, .completeFileProtection])
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var directory = folder
    try directory.setResourceValues(values)
    let config = ARWorldTrackingConfiguration()
    config.worldAlignment = .gravity
    config.planeDetection = [.horizontal]
    if let format = ARWorldTrackingConfiguration.supportedVideoFormats.filter({
      let size = $0.imageResolution
      return size.width <= Self.walkWidth && $0.framesPerSecond == 30
        && abs(size.width * 3 - size.height * 4) < 1
    }).max(by: { $0.imageResolution.width < $1.imageResolution.width }) {
      config.videoFormat = format
    }
    view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    coverageEngine.reset(view: view)
    running = true
    UIApplication.shared.isIdleTimerDisabled = true
  }

  // MARK: Spot actions (main thread)

  func beginSpot() {
    guard running, phase == .map else { return }
    var tracked = false
    if case .normal = view.session.currentFrame?.camera.trackingState { tracked = true }
    guard tracked, let frame = view.session.currentFrame else {
      message = "Hold still for a moment so the camera can find its place."
      return
    }
    let forward = -SIMD3(
      frame.camera.transform.columns.2.x, frame.camera.transform.columns.2.y,
      frame.camera.transform.columns.2.z)
    writer.withBudget({
      $0.canFit(views: SpotLayout.standard.count, averageImage: Self.estimatedSliceBytes)
    }) { [weak self] fits in
      guard let self else { return }
      guard self.session.startSpot(budgetFits: fits, tracking: true) else {
        self.message =
          fits
          ? "This tour has the maximum of \(SpotTake.maximumSpots) spots."
          : "This tour is full. Review your spots and generate the tour."
        return
      }
      self.slicePaths = []
      self.slicePositions = []
      self.pendingSlices = 0
      self.finishing = false
      self.lockCamera()
      self.turn = SpotTurn(startYaw: atan2(-forward.x, -forward.z))
      self.coverageEngine.setOverlayHidden(true)
      self.message = ""
      self.phase = self.session.phase
    }
  }

  func undoSlice() {
    guard case .turning = phase, pendingSlices == 0, !slicePaths.isEmpty,
      turn?.undo() != nil
    else { return }
    // The frame stays on disk for the mesh; it no longer belongs to this spot's panorama.
    slicePaths.removeLast()
    slicePositions.removeLast()
    objectWillChange.send()
  }

  /// Leaves the current turn without saving the spot.
  func cancelSpot() {
    guard case .turning = phase else { return }
    abandonTurn(message: "Spot cancelled. Its views still help the 3D model.")
    session.abandonSpot()
    phase = session.phase
  }

  func deleteSpot(_ number: Int) {
    do {
      try SpotTake.deleteSpot(number, in: folder)
      session.deleteSpot(number)
      spots.removeAll { $0.spot == number }
      refreshCoverage()
    } catch { message = error.localizedDescription }
  }

  /// Deletes a spot and immediately starts a new turn to replace it, while tracking is live.
  func redoSpot(_ number: Int) {
    deleteSpot(number)
    beginSpot()
  }

  /// Ends capture; finished spots stay for review.
  func end() {
    permissionGeneration = UUID()
    requestingPermission = false
    if case .turning = phase { abandonTurn(message: SpotSession.endedMessage) }
    guard running else { return }
    running = false
    view.session.pause()
    UIApplication.shared.isIdleTimerDisabled = false
    session.interrupted()
    phase = session.phase
    hint = nil
  }

  // MARK: ARSessionDelegate

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard running else { return }
    coverageEngine.frameDidUpdate(view: view)
    if startTime == nil { startTime = frame.timestamp }
    let elapsed = frame.timestamp - (startTime ?? frame.timestamp)
    var tracked = false
    if case .normal = frame.camera.trackingState { tracked = true }
    let wasTurning = phase != .map && phase != .relocating
    self.session.trackingChanged(normal: tracked)
    if wasTurning, self.session.phase == .relocating {
      abandonTurn(message: "Tracking was lost, so this spot was discarded. Look around slowly.")
    }
    if phase != self.session.phase { phase = self.session.phase }

    let pose = frame.camera.transform
    let position = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
    let forward = -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
    let here = SIMD2(position.x, position.z)
    if you.map({ simd_distance($0, here) > 0.05 }) ?? true { you = here }
    let points = frame.rawFeaturePoints?.points ?? []
    let source = CIImage(cvPixelBuffer: frame.capturedImage)
    let k = frame.camera.intrinsics
    let dark = (frame.lightEstimate?.ambientIntensity ?? 1000) < 150
    func sample(width: CGFloat) -> CaptureSample {
      let scale = min(1, width / source.extent.width)
      return CaptureSample(
        time: elapsed, position: position, forward: forward, tracking: tracked,
        exposure: frame.camera.exposureDuration, focalLength: k[0][0] * Float(scale),
        sceneDepth: CaptureSample.medianDepth(points, camera: pose), featureCount: points.count)
    }

    switch phase {
    case .map:
      let decision =
        dark
        ? CaptureDecision(reason: .dark)
        : walkPolicy.evaluate(sample(width: Self.walkWidth), canSave: !writer.busy)
      show(decision.reason == .limitReached ? nil : decision.hint, at: elapsed)
      paint(frame, usable: decision.usable, saved: decision.save, at: elapsed)
      if decision.save { save(frame, source: source, width: Self.walkWidth, spot: nil) }
    case .turning(let spot):
      let decision = steadiness.evaluate(sample(width: SpotTake.sliceWidth))
      let steady =
        tracked && !dark && !writer.busy && !finishing
        && (steadiness.motion.map { $0.blur <= CapturePolicy.maximumBlur } ?? false)
      show(dark ? .addLight : (decision.reason == .blurred ? .holdSteadier : nil), at: elapsed)
      paint(frame, usable: decision.usable, saved: false, at: elapsed)
      guard var current = turn else { return }
      let event = current.update(forward: forward, time: elapsed, steady: steady)
      turn = current
      switch event {
      case .capture, .complete:
        slicePositions.append(position)
        if event == .complete { finishing = true }
        save(frame, source: source, width: SpotTake.sliceWidth, spot: spot)
      case .none, .aligning: break
      }
    case .relocating:
      show(.establishTracking, at: elapsed)
    case .ended: break
    }
  }

  func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { updatePlanes(anchors) }
  func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { updatePlanes(anchors) }

  func sessionWasInterrupted(_ session: ARSession) { end() }

  func session(_ session: ARSession, didFailWithError error: Error) {
    message = error.localizedDescription
    end()
  }

  // MARK: Private

  private func updatePlanes(_ anchors: [ARAnchor]) {
    var changed = false
    for case let plane as ARPlaneAnchor in anchors where plane.alignment == .horizontal {
      planes[plane.identifier] = plane.transform.columns.3.y
      changed = true
    }
    if changed { coverageEngine.setFloorPlanes(Array(planes.values)) }
  }

  private func paint(_ frame: ARFrame, usable: Bool, saved: Bool, at time: Double) {
    guard usable, saved || time - lastPaint >= PhotoRecorder.paintInterval else { return }
    lastPaint = time
    coverageEngine.submit(frame)
  }

  private func save(_ frame: ARFrame, source: CIImage, width: CGFloat, spot: Int?) {
    let scale = min(1, width / source.extent.width)
    let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let k = frame.camera.intrinsics
    let pose = frame.camera.transform
    var record = CaptureFrameRecord(
      filePath: "", timestamp: frame.timestamp - (startTime ?? frame.timestamp),
      width: Int(image.extent.width.rounded()), height: Int(image.extent.height.rounded()),
      fx: Double(k[0][0]) * Double(scale), fy: Double(k[1][1]) * Double(scale),
      cx: Double(k[2][0]) * Double(scale), cy: Double(k[2][1]) * Double(scale),
      transformMatrix: (0..<4).map { row in (0..<4).map { column in Double(pose[column][row]) } },
      points: CaptureFrameRecord.points(frame.rawFeaturePoints?.points ?? []))
    if let spot {
      record.role = "slice"
      record.spot = spot
      pendingSlices += 1
    }
    let turnSpot = spot
    writer.save(image, record: record) { [weak self] outcome in
      guard let self else { return }
      guard let turnSpot else {
        if case .failed(let reason) = outcome { self.message = reason }
        return
      }
      self.pendingSlices -= 1
      // Ignore slices of a turn that was abandoned meanwhile.
      guard self.phase == .turning(spot: turnSpot) else { return }
      switch outcome {
      case .saved(let count):
        self.slicePaths.append(String(format: "images/%05d.jpg", count - 1))
        if self.finishing, self.pendingSlices == 0 { self.finishSpot(turnSpot) }
      case .full:
        self.abandonTurn(message: "This tour is full. Review your spots and generate the tour.")
        self.session.abandonSpot()
        self.phase = self.session.phase
      case .failed(let reason):
        self.abandonTurn(message: reason)
        self.session.abandonSpot()
        self.phase = self.session.phase
      }
    }
  }

  private func finishSpot(_ number: Int) {
    let count = Float(max(slicePositions.count, 1))
    let mean = slicePositions.reduce(SIMD3<Float>.zero, +) / count
    let floor = floorY.map(Double.init) ?? Double(mean.y) - Self.assumedEyeHeight
    let record = SpotRecord(
      spot: number, slices: slicePaths, position: [Double(mean.x), Double(mean.y), Double(mean.z)],
      floorY: floor, startYaw: Double(turn?.startYaw ?? 0),
      exposureDuration: lockedExposure.duration, iso: lockedExposure.iso)
    do {
      try SpotTake.appendSpot(record, to: folder)
      spots.append(record)
      session.spotFinished()
    } catch {
      message = error.localizedDescription
      session.abandonSpot()
    }
    unlockCamera()
    turn = nil
    finishing = false
    coverageEngine.setOverlayHidden(false)
    phase = session.phase
    refreshCoverage()
  }

  /// Leaves a turn: unlocks the camera and forgets its slices (they remain walk-only data).
  private func abandonTurn(message text: String) {
    unlockCamera()
    turn = nil
    finishing = false
    slicePaths = []
    slicePositions = []
    coverageEngine.setOverlayHidden(false)
    message = text
  }

  private func refreshCoverage() {
    coverage = FloorCoverage.fraction(
      cells: mapCells,
      spots: spots.map { SIMD2(Float($0.position[0]), Float($0.position[2])) })
  }

  private func show(_ problem: CaptureHint?, at time: Double) {
    let shown = hints.update(problem, at: time)
    if hint != shown { hint = shown }
  }

  /// Every slice of a spot shares one exposure and white balance, so slices blend without
  /// banding.
  private func lockCamera() {
    guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
      (try? device.lockForConfiguration()) != nil
    else { return }
    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
    if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
    lockedExposure = (CMTimeGetSeconds(device.exposureDuration), Double(device.iso))
    device.unlockForConfiguration()
  }

  private func unlockCamera() {
    guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
      (try? device.lockForConfiguration()) != nil
    else { return }
    if device.isExposureModeSupported(.continuousAutoExposure) {
      device.exposureMode = .continuousAutoExposure
    }
    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
      device.whiteBalanceMode = .continuousAutoWhiteBalance
    }
    device.unlockForConfiguration()
  }
}
