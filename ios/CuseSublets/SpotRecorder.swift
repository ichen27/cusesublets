import ARKit
import AVFoundation
import CoreImage
import CoreMotion
import SwiftUI

/// Records a spot tour in one ARKit session. The only pictures taken are the guided slices of
/// a turn at a spot; between spots ARKit follows the phone, so each spot is placed on the map,
/// and nothing is photographed. ARKit only offers the 1× camera, so during a turn it is paused and
/// the 0.5× camera takes the slices, with the motion sensors supplying each slice's rotation. Rules live in `SpotSession`, `SpotTurn` and `SpotTake`; this class
/// connects them to the camera.
final class SpotRecorder: NSObject, ObservableObject, ARSessionDelegate {
  /// Conservative size of one 2880 × 2160 slice, for deciding whether a whole spot still fits.
  /// (1920 × 1440 slices measured 0.3 to 0.5 MB on an iPhone 17.)
  static let estimatedSliceBytes = 1_500_000
  /// Radians per second; faster than this, a slice would blur.
  static let steadyRotation = 0.35
  /// ARKit only tracks between spots, so it runs its camera no larger than this.
  static let trackingWidth: CGFloat = 1920
  /// Seconds without a picture after which the 0.5× camera is started again, and after which
  /// the spot is given up.
  static let cameraRetry = 5.0
  static let cameraTimeout = 15.0
  /// Used when no floor has been seen yet: typical phone height above the floor.
  static let assumedEyeHeight = 1.45
  /// Metres from the person's pivot to the phone held out in front of them.
  static let armLength: Float = 0.35
  /// Seconds of ARKit frames ignored after its origin is moved, while the change takes effect.
  static let settleTime = 0.3

  @Published private(set) var phase = SpotPhase.map
  @Published private(set) var turn: SpotTurn?
  @Published private(set) var spots: [SpotRecord] = []
  @Published private(set) var you: SIMD2<Float>?
  @Published private(set) var running = false
  @Published private(set) var requestingPermission = false
  /// A spot was asked for and opens as soon as the camera knows where it is.
  @Published private(set) var opening = false
  /// The 0.5× camera has delivered a picture in this turn. Until then its screen is black.
  @Published private(set) var cameraLive = false
  /// Spots whose sketch for the map is still being drawn.
  @Published private(set) var sketching: Set<Int> = []
  /// The shots of the turn in progress, for showing them where they were taken.
  @Published private(set) var pinned: [PinnedShot] = []
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
  private let log = SpotDiagnostics.shared
  /// Counts turns, so a check scheduled for one turn does nothing in a later one.
  private var turnSerial = 0
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
  private var checkingBudget = false
  /// When the spot being opened was asked for, and when its camera's first picture arrived.
  private var askedAt: Double?
  private var firstWideFrame: Double?
  private var cameraDelay: Double?
  private var pinSerial = 0
  private let stillContext = CIContext()
  /// As wide as the screen in pixels, so a pinned shot looks as sharp as the live camera did.
  static let pinnedWidth: CGFloat = 1080
  /// The correction applied after the previous turn, recorded with the next spot.
  private var lastRealign: (yaw: Double, shift: Double)?
  private var exposureLocked = false
  /// The 0.5× camera's focal length and picture size, in pixels. Until its first picture
  /// arrives this is its usual shape (103° across the long side), so the dot can be drawn the
  /// moment the camera screen opens.
  private var lens: (focal: Float, image: CGSize) = (1602, CGSize(width: 4032, height: 3024))
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
    wide.onEvent = { [log] text in log.note("camera: " + text) }
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
      return size.width <= Self.trackingWidth && $0.framesPerSecond == 30
        && abs(size.width * 3 - size.height * 4) < 1
    }).max(by: { $0.imageResolution.width < $1.imageResolution.width }) {
      config.videoFormat = format
    }
    view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    arConfiguration = config
    motion.deviceMotionUpdateInterval = 1.0 / 60
    motion.startDeviceMotionUpdates(using: .xArbitraryZVertical)
    wide.onFrame = { [weak self] frame in self?.turnFrame(frame) }
    log.note("capture started")
    // Loading the depth model takes a while; do it now, not when the first spot's sketch waits.
    DispatchQueue.global(qos: .utility).async { _ = DepthEstimator.shared }
    running = true
    UIApplication.shared.isIdleTimerDisabled = true
  }

  // MARK: Spot actions (main thread)

  /// A new camera is still choosing its exposure, and a spot keeps the exposure of its first
  /// shot. `seconds` is the time since the camera's first picture.
  static func exposureSettled(after seconds: Double, adjusting: Bool) -> Bool {
    seconds >= 0.5 && (!adjusting || seconds >= 1.5)
  }

  /// The button on the map: opens the 0.5× camera where the person stands, with the first dot
  /// straight ahead, ready to capture. If the camera does not know where it is yet, the spot
  /// opens as soon as it does.
  func openSpot() {
    guard running, phase == .map, turn == nil, !checkingBudget else { return }
    guard WideCamera.isAvailable else {
      message = "Spot capture needs an iPhone with a 0.5× camera."
      return
    }
    guard spotsRemaining > 0 else {
      message = "This tour has the maximum of \(SpotTake.maximumSpots) spots."
      return
    }
    if !opening {
      opening = true
      askedAt = CACurrentMediaTime()
      message = ""
      log.note("spot asked for, position known: \(trackedPose() != nil)")
    }
    // Without a tracked pose there is nowhere to put the spot; the next tracked frame tries again.
    guard trackedPose() != nil else { return }
    checkingBudget = true
    writer.withBudget({
      $0.canFit(views: SpotLayout.standard.count, averageImage: Self.estimatedSliceBytes)
    }) { [weak self] fits in
      guard let self else { return }
      self.checkingBudget = false
      guard self.running, self.opening, self.phase == .map else { return }
      guard fits else {
        self.opening = false
        self.message = "This tour is full. Review your spots and generate the tour."
        return
      }
      guard let (pose, sample) = self.trackedPose() else { return }
      guard self.session.startSpot(budgetFits: true, tracking: true) else {
        self.opening = false
        return
      }
      self.beginTurn(pose: pose, sample: sample)
    }
  }

  /// Where ARKit says the phone is, when that can be trusted.
  private func trackedPose() -> (simd_float4x4, CMDeviceMotion)? {
    guard realign == nil, !trackingPaused, let frame = view.session.currentFrame,
      frame.timestamp >= settleUntil, case .normal = frame.camera.trackingState,
      let sample = motion.deviceMotion
    else { return nil }
    return (frame.camera.transform, sample)
  }

  /// Hands the camera from ARKit, which only tracks with the 1× lens, to the 0.5× camera, and
  /// starts the turn with the first dot the way the person faces.
  private func beginTurn(pose: simd_float4x4, sample: CMDeviceMotion) {
    let cameraToWorld = simd_float3x3(
      SIMD3(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z),
      SIMD3(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z),
      SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))
    spotOrigin = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
    startFacing = SpotOrientation.facing(cameraToWorld: cameraToWorld)
    orientation = SpotOrientation(
      cameraToWorld: cameraToWorld, deviceToReference: SpotOrientation.deviceToReference(sample))
    // Someone looking down at the map still faces the way the top of the phone points.
    let ahead = startFacing ?? -cameraToWorld.columns.2
    slicePaths = []
    pendingSlices = 0
    finishing = false
    exposureLocked = false
    firstWideFrame = nil
    cameraDelay = nil
    cameraLive = false
    trackingPaused = true
    view.session.pause()
    turn = SpotTurn(startYaw: atan2(-ahead.x, -ahead.z))
    opening = false
    message = ""
    phase = session.phase
    turnSerial += 1
    log.note("turn begun \(sinceAsked()) after asking; tracking paused, starting the 0.5× camera")
    wide.start { [weak self] problem in
      guard let self, let problem, case .turning = self.phase else { return }
      self.giveUpTurn(message: problem)
    }
    watchCamera(turn: turnSerial, after: Self.cameraRetry)
  }

  private func sinceAsked() -> String {
    askedAt.map { "\(Int(((CACurrentMediaTime() - $0) * 1000).rounded())) ms" } ?? "?"
  }

  /// A camera that shows nothing is started once more, then the spot is given up, so the
  /// person is never left on a black screen.
  private func watchCamera(turn serial: Int, after seconds: Double) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
      guard let self, self.turnSerial == serial, case .turning = self.phase, !self.cameraLive
      else { return }
      if seconds < Self.cameraTimeout {
        self.log.note("no picture \(self.sinceAsked()) after asking; starting the camera again")
        self.wide.restart()
        self.watchCamera(turn: serial, after: Self.cameraTimeout - Self.cameraRetry)
      } else {
        self.log.note("no picture \(self.sinceAsked()) after asking; giving up")
        self.giveUpTurn(message: "The camera did not start. Tap Capture Here to try again.")
      }
    }
  }

  private func giveUpTurn(message text: String) {
    abandonTurn(message: text)
    session.abandonSpot()
    phase = session.phase
  }

  func undoSlice() {
    guard case .turning = phase, pendingSlices == 0, !slicePaths.isEmpty,
      turn?.undo() != nil
    else { return }
    // The frame stays on disk for the mesh; it no longer belongs to this spot's panorama.
    slicePaths.removeLast()
    if !pinned.isEmpty { pinned.removeLast() }
    objectWillChange.send()
  }

  /// Leaves the current turn without saving the spot.
  func cancelSpot() {
    guard case .turning = phase else { return }
    let taken = !slicePaths.isEmpty || pendingSlices > 0
    log.note("spot cancelled \(sinceAsked()) after asking, camera live: \(cameraLive)")
    abandonTurn(message: taken ? "Cancelled. Its views still help the 3D model." : "")
    session.abandonSpot()
    phase = session.phase
  }

  func deleteSpot(_ number: Int) {
    do {
      try SpotTake.deleteSpot(number, in: folder)
      session.deleteSpot(number)
      spots.removeAll { $0.spot == number }
      patches[number] = nil
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
    } catch { message = error.localizedDescription }
  }

  /// Deletes a spot and immediately starts a new turn to replace it, while tracking is live.
  func redoSpot(_ number: Int) {
    deleteSpot(number)
    openSpot()
  }

  /// Ends capture; finished spots stay for review.
  func end() {
    permissionGeneration = UUID()
    requestingPermission = false
    if case .turning = phase { abandonTurn(message: SpotSession.endedMessage) }
    opening = false
    guard running else { return }
    running = false
    wide.stop()
    motion.stopDeviceMotionUpdates()
    view.session.pause()
    UIApplication.shared.isIdleTimerDisabled = false
    session.interrupted()
    phase = session.phase
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
      log.note("tracking found its place again")
      return
    }
    guard frame.timestamp >= settleUntil else { return }
    if startTime == nil { startTime = frame.timestamp }
    var tracked = false
    if case .normal = frame.camera.trackingState { tracked = true }
    self.session.trackingChanged(normal: tracked)
    if phase != self.session.phase { phase = self.session.phase }
    guard tracked else { return }
    let pose = frame.camera.transform
    let here = SIMD2(pose.columns.3.x, pose.columns.3.z)
    if you.map({ simd_distance($0, here) > 0.05 }) ?? true { you = here }
    // A spot asked for before the camera knew where it was opens now.
    if phase == .map, opening { openSpot() }
  }

  func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { updatePlanes(anchors) }
  func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { updatePlanes(anchors) }

  func sessionWasInterrupted(_ session: ARSession) { end() }

  func session(_ session: ARSession, didFailWithError error: Error) {
    message = error.localizedDescription
    end()
  }

  // MARK: Private

  /// The floor is the lowest level surface ARKit has found. It is kept through a turn, when
  /// tracking starts afresh and has found no surfaces yet.
  private func updatePlanes(_ anchors: [ARAnchor]) {
    // Until restarted tracking is lined up with the tour's world, its heights are not the tour's.
    guard realign == nil else { return }
    for case let plane as ARPlaneAnchor in anchors where plane.alignment == .horizontal {
      planes[plane.identifier] = plane.transform.columns.3.y
    }
    if let lowest = FloorCoverage.estimateFloorY(planes: Array(planes.values), cells: []) {
      floorY = lowest
    }
  }

  /// One 0.5× frame while turning: advances the turn and saves the frame when a dot is held.
  private func turnFrame(_ frame: WideFrame) {
    guard running, case .turning(let spot) = phase, var current = turn, let orientation,
      let sample = motion.deviceMotion
    else { return }
    lens = (frame.fx, CGSize(width: frame.width, height: frame.height))
    if firstWideFrame == nil {
      firstWideFrame = frame.timestamp
      cameraDelay = askedAt.map { CACurrentMediaTime() - $0 }
      cameraLive = true
      log.note("first picture \(sinceAsked()) after asking, \(frame.width)×\(frame.height)")
    }
    let attitude = SpotOrientation.deviceToReference(sample)
    let rate = sample.rotationRate
    let speed = (rate.x * rate.x + rate.y * rate.y + rate.z * rate.z).squareRoot()
    let settled =
      exposureLocked
      || Self.exposureSettled(
        after: frame.timestamp - (firstWideFrame ?? frame.timestamp),
        adjusting: wide.adjustingExposure)
    let steady = speed < Self.steadyRotation && !writer.busy && !finishing && settled
    let time = frame.timestamp - (startTime ?? frame.timestamp)
    let event = current.update(forward: orientation.forward(attitude), time: time, steady: steady)
    turn = current
    switch event {
    case .aligning:
      // Lock once the first dot is lined up, so every slice of the spot shares one exposure.
      if !exposureLocked {
        lockedExposure = wide.lockExposure()
        exposureLocked = true
        log.note("exposure locked \(sinceAsked()) after asking")
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
      pin(source, frame: frame, rotation: orientation.worldFromDevice(attitude))
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

  /// Keeps a small upright copy of a shot to show where it was taken.
  private func pin(_ source: CIImage, frame: WideFrame, rotation: simd_float3x3) {
    // The sensor's picture is landscape; held upright, it reads correctly turned a quarter.
    let upright = source.oriented(.right)
    let scale = min(1, Self.pinnedWidth / upright.extent.width)
    let small = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard frame.fx > 0, frame.fy > 0,
      let image = stillContext.createCGImage(small, from: small.extent)
    else { return }
    pinSerial += 1
    pinned.append(
      PinnedShot(
        id: pinSerial, image: image, rotation: rotation,
        halfWidth: Float(frame.height) / 2 / frame.fy, halfHeight: Float(frame.width) / 2 / frame.fx))
  }

  /// The phone's rotation in the tour's world now, while the 0.5× camera is running.
  var deviceRotation: simd_float3x3? {
    guard let orientation, let sample = motion.deviceMotion else { return nil }
    return orientation.worldFromDevice(SpotOrientation.deviceToReference(sample))
  }

  /// Tangent of half the 0.5× camera's view across an upright screen.
  var viewHalfWidth: Float {
    guard lens.focal > 0 else { return 0.95 }
    return Float(lens.image.height) / 2 / lens.focal
  }

  /// Where a world direction is on the 0.5× camera preview, for drawing the dots.
  func screenPoint(of direction: SIMD3<Float>, in screen: CGSize) -> (point: CGPoint, ahead: Bool)? {
    guard let orientation, let sample = motion.deviceMotion else { return nil }
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
      resumeYaw: lastRealign?.yaw, resumeShift: lastRealign?.shift, cameraDelay: cameraDelay)
    do {
      try SpotTake.appendSpot(record, to: folder)
      spots.append(record)
      session.spotFinished()
      message = "Captured. Walk to where you want the next view, then tap Capture Here."
      log.note("spot finished \(sinceAsked()) after asking")
      drawFloor(of: record)
    } catch {
      message = error.localizedDescription
      session.abandonSpot()
    }
    resumeTracking()
    turn = nil
    pinned = []
    finishing = false
    phase = session.phase
  }

  /// Leaves a turn: returns the camera to ARKit and forgets its slices.
  private func abandonTurn(message text: String) {
    resumeTracking()
    turn = nil
    pinned = []
    finishing = false
    slicePaths = []
    message = text
  }

  /// Makes the top-down sketch of the room around a finished spot, off the main thread, and
  /// records how long the person waited for it.
  private func drawFloor(of spot: SpotRecord) {
    let folder = self.folder
    let asked = CACurrentMediaTime()
    sketching.insert(spot.spot)
    writer.afterPendingWrites { [weak self] _ in
      DispatchQueue.global(qos: .userInitiated).async {
        let frames = (try? PhotoRecorder.savedFrames(in: folder)) ?? []
        let picture = FloorPatch.make(spot: spot, frames: frames, folder: folder)
        DispatchQueue.main.async {
          guard let self else { return }
          self.sketching.remove(spot.spot)
          guard let index = self.spots.firstIndex(where: { $0.spot == spot.spot }) else { return }
          self.patches[spot.spot] = picture
          self.spots[index].sketchDelay = CACurrentMediaTime() - asked
          self.log.note("sketch drawn \(Int(((CACurrentMediaTime() - asked) * 1000).rounded())) ms after the spot")
          try? SpotTake.appendSpot(self.spots[index], to: folder)
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
