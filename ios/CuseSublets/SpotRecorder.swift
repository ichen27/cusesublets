import ARKit
import AVFoundation
import CoreImage
import CoreMotion
import SwiftUI

/// Records a spot tour in one ARKit session: walk frames on the capture map, guided slices
/// while turning at a spot. ARKit only offers the 1× camera, so during a turn it is paused and
/// the 0.5× camera takes the slices, with the motion sensors supplying each slice's rotation. Rules live in `SpotSession`, `SpotTurn` and `SpotTake`; this class
/// connects them to the camera.
final class SpotRecorder: NSObject, ObservableObject, ARSessionDelegate {
  /// Conservative size of one 1920 × 1440 slice, for deciding whether a whole spot still fits.
  static let estimatedSliceBytes = 900_000
  /// Radians per second; faster than this, a slice would blur.
  static let steadyRotation = 0.35
  static let walkWidth: CGFloat = 1920
  /// Used when no floor has been seen yet: typical phone height above the floor.
  static let assumedEyeHeight = 1.45
  /// Metres from the person's pivot to the phone held out in front of them.
  static let armLength: Float = 0.35
  /// Seconds of ARKit frames ignored after its origin is moved, while the change takes effect.
  static let settleTime = 0.3

  @Published private(set) var phase = SpotPhase.map
  @Published private(set) var turn: SpotTurn?
  @Published private(set) var spots: [SpotRecord] = []
  @Published private(set) var mapCells: [TopDownCell] = []
  @Published private(set) var coverage: Double = 0
  @Published private(set) var hint: CaptureHint?
  @Published private(set) var you: SIMD2<Float>?
  @Published private(set) var running = false
  @Published private(set) var requestingPermission = false
  /// Top-down sketches of the room around each finished spot, by spot number.
  @Published private(set) var patches: [Int: UIImage] = [:]
  @Published var message = ""

  let view = ARSCNView(frame: .zero)
  let wide = WideCamera()
  let draft: PhotoCaptureDraft
  let folder: URL
  var canGenerate: Bool { session.canGenerate }
  var spotsRemaining: Int { SpotTake.maximumSpots - session.completed.count }

  private var session: SpotSession
  private let writer: CaptureWriter
  private let coverageEngine = CaptureCoverageEngine()
  private var walkPolicy = CapturePolicy(
    maximumViews: SpotTake.maximumWalkFrames, maximumDuration: .infinity)
  private var hints = CaptureHintFilter()
  private var lastPaint = -Double.infinity
  private var startTime: TimeInterval?
  private var floorY: Float?
  private var planes = [UUID: Float]()
  private var permissionGeneration = UUID()
  private var observer: NSObjectProtocol?
  // The spot being turned.
  private var slicePaths = [String]()
  private let motion = CMMotionManager()
  private var arConfiguration: ARWorldTrackingConfiguration?
  /// ARKit is paused while the 0.5× camera turns at a spot.
  private var trackingPaused = false
  private var orientation: SpotOrientation?
  private var spotOrigin = SIMD3<Float>.zero
  private var startFacing: SIMD3<Float>?
  /// Set while ARKit, restarted after a turn, still has to be lined up with the tour's world.
  private var realign: (orientation: SpotOrientation, origin: SIMD3<Float>, facing: SIMD3<Float>?)?
  private var settleUntil = -Double.infinity
  /// The correction applied after the previous turn, recorded with the next spot.
  private var lastRealign: (yaw: Double, shift: Double)?
  private var exposureLocked = false
  private var lens: (focal: Float, image: CGSize)?
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
    let folder = self.folder
    if !saved.isEmpty {
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let pictures = FloorPatch.load(folder: folder, spots: saved, frames: frames)
        DispatchQueue.main.async { self?.patches = pictures }
      }
    }
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
    arConfiguration = config
    motion.deviceMotionUpdateInterval = 1.0 / 60
    motion.startDeviceMotionUpdates(using: .xArbitraryZVertical)
    wide.onFrame = { [weak self] frame in self?.turnFrame(frame) }
    coverageEngine.reset(view: view)
    running = true
    UIApplication.shared.isIdleTimerDisabled = true
  }

  // MARK: Spot actions (main thread)

  func beginSpot() {
    guard running, phase == .map else { return }
    guard realign == nil else {
      message = "Hold still for a moment so the camera can find its place."
      return
    }
    var tracked = false
    if case .normal = view.session.currentFrame?.camera.trackingState { tracked = true }
    guard tracked, let frame = view.session.currentFrame, let sample = motion.deviceMotion else {
      message = "Hold still for a moment so the camera can find its place."
      return
    }
    guard WideCamera.isAvailable else {
      message = "Spot capture needs an iPhone with a 0.5× camera."
      return
    }
    let pose = frame.camera.transform
    let forward = -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
    let cameraToWorld = simd_float3x3(
      SIMD3(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z),
      SIMD3(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z),
      SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))
    let origin = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
    let attitude = SpotOrientation.deviceToReference(sample)
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
      self.pendingSlices = 0
      self.finishing = false
      self.exposureLocked = false
      self.lens = nil
      self.spotOrigin = origin
      self.startFacing = SpotOrientation.facing(cameraToWorld: cameraToWorld)
      self.orientation = SpotOrientation(cameraToWorld: cameraToWorld, deviceToReference: attitude)
      self.turn = SpotTurn(startYaw: atan2(-forward.x, -forward.z))
      self.coverageEngine.setOverlayHidden(true)
      self.message = ""
      self.phase = self.session.phase
      // Hand the camera from ARKit to the 0.5× lens for the turn.
      self.trackingPaused = true
      self.view.session.pause()
      self.wide.start { [weak self] problem in
        guard let self, let problem, case .turning = self.phase else { return }
        self.abandonTurn(message: problem)
        self.session.abandonSpot()
        self.phase = self.session.phase
      }
    }
  }

  func undoSlice() {
    guard case .turning = phase, pendingSlices == 0, !slicePaths.isEmpty,
      turn?.undo() != nil
    else { return }
    // The frame stays on disk for the mesh; it no longer belongs to this spot's panorama.
    slicePaths.removeLast()
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
      patches[number] = nil
      refreshCoverage()
    } catch { message = error.localizedDescription }
  }

  /// Puts a spot where the person dragged it on the map (metres, world x and z).
  func moveSpot(_ number: Int, to place: SIMD2<Float>) {
    do {
      try SpotTake.moveSpot(number, to: place, in: folder)
      if let index = spots.firstIndex(where: { $0.spot == number }) {
        spots[index].position[0] = Double(place.x)
        spots[index].position[2] = Double(place.y)
      }
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
    wide.stop()
    motion.stopDeviceMotionUpdates()
    view.session.pause()
    UIApplication.shared.isIdleTimerDisabled = false
    session.interrupted()
    phase = session.phase
    hint = nil
    // Writes may still be in flight; discard only after they finish.
    let folder = self.folder
    writer.afterPendingWrites { _ in
      let removed = (try? SpotTake.discardIfEmpty(folder: folder)) ?? false
      if removed {
        DispatchQueue.main.async { self.message = "No spot was finished, so nothing was kept." }
      }
    }
  }

  // MARK: ARSessionDelegate

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard running, !trackingPaused else { return }
    if let pending = realign {
      // ARKit restarted with a new origin. Once it tracks, line it up with the tour's world:
      // the motion sensors kept the phone's heading through the turn.
      guard case .normal = frame.camera.trackingState, let sample = motion.deviceMotion else {
        show(.establishTracking, at: frame.timestamp - (startTime ?? frame.timestamp))
        return
      }
      let expected = pending.orientation.cameraToWorld(SpotOrientation.deviceToReference(sample))
      let place = SpotOrientation.swung(
        from: pending.origin, startFacing: pending.facing,
        facing: SpotOrientation.facing(cameraToWorld: expected), arm: Self.armLength)
      let correction = SpotOrientation.realignment(
        expected: expected, position: place, reported: frame.camera.transform)
      session.setWorldOrigin(relativeTransform: correction.inverse)
      let shift = correction.columns.3
      lastRealign = (
        Double(SpotOrientation.yawDegrees(of: correction)),
        Double(simd_length(SIMD3(shift.x, shift.y, shift.z)))
      )
      realign = nil
      settleUntil = frame.timestamp + Self.settleTime
      return
    }
    guard frame.timestamp >= settleUntil else { return }
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
      if decision.save { saveWalk(frame, source: source) }
    case .turning: break
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

  private func saveWalk(_ frame: ARFrame, source: CIImage) {
    let scale = min(1, Self.walkWidth / source.extent.width)
    let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let k = frame.camera.intrinsics
    let pose = frame.camera.transform
    let record = CaptureFrameRecord(
      filePath: "", timestamp: frame.timestamp - (startTime ?? frame.timestamp),
      width: Int(image.extent.width.rounded()), height: Int(image.extent.height.rounded()),
      fx: Double(k[0][0]) * Double(scale), fy: Double(k[1][1]) * Double(scale),
      cx: Double(k[2][0]) * Double(scale), cy: Double(k[2][1]) * Double(scale),
      transformMatrix: (0..<4).map { row in (0..<4).map { column in Double(pose[column][row]) } },
      points: CaptureFrameRecord.points(frame.rawFeaturePoints?.points ?? []))
    save(image, record: record, spot: nil)
  }

  /// One 0.5× frame while turning: advances the turn and saves the frame when a dot is held.
  private func turnFrame(_ frame: WideFrame) {
    guard running, case .turning(let spot) = phase, var current = turn, let orientation,
      let sample = motion.deviceMotion
    else { return }
    lens = (frame.fx, CGSize(width: frame.width, height: frame.height))
    let attitude = SpotOrientation.deviceToReference(sample)
    let rate = sample.rotationRate
    let speed = (rate.x * rate.x + rate.y * rate.y + rate.z * rate.z).squareRoot()
    let steady = speed < Self.steadyRotation && !writer.busy && !finishing
    let time = frame.timestamp - (startTime ?? frame.timestamp)
    let event = current.update(forward: orientation.forward(attitude), time: time, steady: steady)
    turn = current
    switch event {
    case .aligning:
      // Lock once the first dot is lined up, so every slice of the spot shares one exposure.
      if !exposureLocked {
        lockedExposure = wide.lockExposure()
        exposureLocked = true
      }
    case .capture, .complete:
      if event == .complete { finishing = true }
      let source = CIImage(cvPixelBuffer: frame.image)
      let scale = min(1, SpotTake.sliceWidth / source.extent.width)
      let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      let r = orientation.cameraToWorld(attitude)
      let transform: [[Double]] = [
        [Double(r[0][0]), Double(r[1][0]), Double(r[2][0]), Double(spotOrigin.x)],
        [Double(r[0][1]), Double(r[1][1]), Double(r[2][1]), Double(spotOrigin.y)],
        [Double(r[0][2]), Double(r[1][2]), Double(r[2][2]), Double(spotOrigin.z)],
        [0, 0, 0, 1],
      ]
      var record = CaptureFrameRecord(
        filePath: "", timestamp: time, width: Int(image.extent.width.rounded()),
        height: Int(image.extent.height.rounded()), fx: Double(frame.fx) * Double(scale),
        fy: Double(frame.fy) * Double(scale), cx: Double(frame.cx) * Double(scale),
        cy: Double(frame.cy) * Double(scale), transformMatrix: transform, points: [])
      record.role = "slice"
      record.spot = spot
      pendingSlices += 1
      save(image, record: record, spot: spot)
    case .none: break
    }
  }

  /// Where a world direction is on the 0.5× camera preview, for drawing the dots.
  func screenPoint(of direction: SIMD3<Float>, in screen: CGSize) -> (point: CGPoint, ahead: Bool)? {
    guard let orientation, let lens, let sample = motion.deviceMotion else { return nil }
    return orientation.screenPoint(
      of: direction, deviceToReference: SpotOrientation.deviceToReference(sample),
      focal: lens.focal, image: lens.image, screen: screen)
  }

  private func save(_ image: CIImage, record: CaptureFrameRecord, spot: Int?) {
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
    let origin = spotOrigin
    let floor = floorY.map(Double.init) ?? Double(origin.y) - Self.assumedEyeHeight
    let record = SpotRecord(
      spot: number, slices: slicePaths,
      position: [Double(origin.x), Double(origin.y), Double(origin.z)],
      floorY: floor, startYaw: Double(turn?.startYaw ?? 0),
      exposureDuration: lockedExposure.duration, iso: lockedExposure.iso, lens: "ultrawide",
      gravityMismatch: orientation.map { Double($0.gravityMismatchDegrees) },
      resumeYaw: lastRealign?.yaw, resumeShift: lastRealign?.shift)
    do {
      try SpotTake.appendSpot(record, to: folder)
      spots.append(record)
      session.spotFinished()
      message = "Spot \(number) captured. Walk to the next spot, then tap Start Capture."
      drawFloor(of: record)
    } catch {
      message = error.localizedDescription
      session.abandonSpot()
    }
    resumeTracking()
    turn = nil
    finishing = false
    coverageEngine.setOverlayHidden(false)
    phase = session.phase
    refreshCoverage()
  }

  /// Leaves a turn: returns the camera to ARKit and forgets its slices (they remain walk-only data).
  private func abandonTurn(message text: String) {
    resumeTracking()
    turn = nil
    finishing = false
    slicePaths = []
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

  /// Makes the top-down sketch of the room around a finished spot, off the main thread.
  private func drawFloor(of spot: SpotRecord) {
    let folder = self.folder
    writer.afterPendingWrites { [weak self] _ in
      DispatchQueue.global(qos: .userInitiated).async {
        let frames = (try? PhotoRecorder.savedFrames(in: folder)) ?? []
        let picture = FloorPatch.make(spot: spot, frames: frames, folder: folder)
        DispatchQueue.main.async {
          guard let self, self.spots.contains(where: { $0.spot == spot.spot }) else { return }
          self.patches[spot.spot] = picture
        }
      }
    }
  }

  /// Returns the camera from the 0.5× lens to ARKit. A paused session resumes as if the phone
  /// had not moved, which put later spots in the wrong place, so tracking starts afresh and the
  /// first tracked frame is lined up with the tour's world (see `session(_:didUpdate:)`).
  private func resumeTracking() {
    guard trackingPaused else { return }
    let pending = orientation.map { ($0, spotOrigin, startFacing) }
    orientation = nil
    wide.stop { [weak self] in
      guard let self, self.running, let configuration = self.arConfiguration else { return }
      if let pending {
        self.realign = (pending.0, pending.1, pending.2)
        // The old floor planes belong to the old origin.
        self.planes = [:]
        self.view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
      } else {
        self.view.session.run(configuration)
      }
      self.trackingPaused = false
    }
  }
}
