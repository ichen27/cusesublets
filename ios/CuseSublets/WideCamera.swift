import AVFoundation
import CoreImage
import UIKit

/// One frame from the 0.5× camera, in sensor (landscape) orientation.
struct WideFrame {
  let image: CVPixelBuffer
  let width: Int
  let height: Int
  let fx: Float
  let fy: Float
  let cx: Float
  let cy: Float
  let timestamp: Double
}

/// The ultra-wide (0.5×) back camera, used while turning at a spot. ARKit's world tracking only
/// offers the 1× camera, so it is paused while this runs.
final class WideCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  /// Slices are saved 2880 wide. The camera runs at the smallest format at least that wide
  /// (4032 × 3024 on current iPhones), so a slice is scaled down from more detail, not up.
  static let targetWidth: Int32 = 2880

  let previewLayer = AVCaptureVideoPreviewLayer()
  /// Called on the main queue for each delivered frame.
  var onFrame: ((WideFrame) -> Void)?
  /// Called, on any queue, with what the camera did and how long it took: for finding out why
  /// a start was slow or failed.
  var onEvent: ((String) -> Void)?

  private let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "cuse.wide-camera")
  private var device: AVCaptureDevice?
  private var configured = false
  private var delivering = false
  /// The camera has been asked to run and not yet to stop.
  private var wanted = false
  /// Width of the pictures asked for, once the camera has been set to it. Until then, and for
  /// pictures of another size still on their way, nothing is delivered.
  private var wantedWidth: Int?
  private var watchers = [NSObjectProtocol]()

  static var isAvailable: Bool {
    AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil
  }

  override init() {
    super.init()
    previewLayer.session = session
    // Show the whole frame, as the Camera app does at 0.5×. Filling a tall screen would crop
    // the sides to about the 1× camera's view.
    previewLayer.videoGravity = .resizeAspect
    let center = NotificationCenter.default
    watchers = [
      center.addObserver(
        forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
      ) { [weak self] note in
        let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        self?.onEvent?("interrupted, reason \(reason.map(String.init) ?? "unknown")")
      },
      center.addObserver(
        forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
      ) { [weak self] _ in
        self?.onEvent?("interruption ended")
        self?.resume()
      },
      center.addObserver(
        forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
      ) { [weak self] note in
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        self?.onEvent?("runtime error \(error?.code ?? 0)")
        self?.resume()
      },
    ]
  }
  deinit { watchers.forEach(NotificationCenter.default.removeObserver) }

  /// Starts the session again if it should be running and is not, as after an interruption.
  private func resume() {
    queue.async {
      guard self.wanted, !self.session.isRunning else { return }
      self.wantedWidth = nil
      self.session.startRunning()
      let format = (try? self.chooseFormat()) ?? "format not set"
      self.onEvent?("started again, running: \(self.session.isRunning); \(format)")
    }
  }

  /// Stops and starts a camera that is showing nothing.
  func restart() {
    queue.async {
      guard self.wanted else { return }
      if self.session.isRunning { self.session.stopRunning() }
      self.wantedWidth = nil
      self.session.startRunning()
      let format = (try? self.chooseFormat()) ?? "format not set"
      self.onEvent?(
        "restarted, running: \(self.session.isRunning), interrupted: \(self.session.isInterrupted); \(format)")
    }
  }

  /// Starts the camera; `completion` gets an error message, or nil once it is running.
  ///
  /// The session is started before the camera's picture size is set. ARKit uses this lens too
  /// and holds on to it for a while after it is paused: setting the size first waited about
  /// nine seconds for it on an iPhone 17. Starting first takes the camera, and the first
  /// full-size frame then arrives in about 0.8 s. Frames are delivered once the size is set.
  func start(completion: @escaping (String?) -> Void) {
    queue.async {
      func ms(_ from: Double) -> Int { Int(((CACurrentMediaTime() - from) * 1000).rounded()) }
      do {
        self.wanted = true
        var mark = CACurrentMediaTime()
        try self.configure()
        let configuring = ms(mark)
        self.wantedWidth = nil
        mark = CACurrentMediaTime()
        self.session.startRunning()
        let starting = ms(mark)
        // An interrupted session starts by itself when the interruption ends, so that is not
        // yet a failure: whoever started the camera decides how long to wait for a picture.
        let running = self.session.isRunning
        let interrupted = self.session.isInterrupted
        self.onEvent?(
          "set up \(configuring) ms, start \(starting) ms, running: \(running), interrupted: \(interrupted)")
        if running || interrupted { self.onEvent?(try self.chooseFormat()) }
        DispatchQueue.main.async {
          if let connection = self.previewLayer.connection,
            connection.isVideoRotationAngleSupported(90)
          {
            connection.videoRotationAngle = 90
          }
          completion(running || interrupted ? nil : "The 0.5× camera could not start.")
        }
      } catch {
        self.onEvent?("could not be set up: \(error.localizedDescription)")
        DispatchQueue.main.async { completion(error.localizedDescription) }
      }
    }
  }

  func stop(completion: (() -> Void)? = nil) {
    queue.async {
      self.wanted = false
      if self.session.isRunning { self.session.stopRunning() }
      self.unlockExposure()
      if let completion { DispatchQueue.main.async(execute: completion) }
    }
  }

  /// Whether the camera is still changing its exposure.
  var adjustingExposure: Bool { device?.isAdjustingExposure ?? false }

  /// Fixes exposure and white balance where they are now; returns the locked values.
  func lockExposure() -> (duration: Double, iso: Double) {
    guard let device, (try? device.lockForConfiguration()) != nil else { return (0, 0) }
    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
    if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
    let values = (CMTimeGetSeconds(device.exposureDuration), Double(device.iso))
    device.unlockForConfiguration()
    return values
  }

  private func unlockExposure() {
    guard let device, (try? device.lockForConfiguration()) != nil else { return }
    if device.isExposureModeSupported(.continuousAutoExposure) {
      device.exposureMode = .continuousAutoExposure
    }
    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
      device.whiteBalanceMode = .continuousAutoWhiteBalance
    }
    device.unlockForConfiguration()
  }

  private func configure() throws {
    guard !configured else { return }
    guard
      let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
    else { throw CaptureFailure.message("This iPhone has no 0.5× camera.") }
    let input = try AVCaptureDeviceInput(device: device)
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    session.sessionPreset = .inputPriority
    guard session.canAddInput(input) else {
      throw CaptureFailure.message("The 0.5× camera is unavailable.")
    }
    session.addInput(input)
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    ]
    output.setSampleBufferDelegate(self, queue: queue)
    guard session.canAddOutput(output) else {
      throw CaptureFailure.message("The 0.5× camera is unavailable.")
    }
    session.addOutput(output)
    if let connection = output.connection(with: .video),
      connection.isCameraIntrinsicMatrixDeliverySupported
    {
      connection.isCameraIntrinsicMatrixDeliveryEnabled = true
    }
    self.device = device
    configured = true
  }

  /// Sets the camera's format at every start, not once: between turns ARKit runs this same
  /// lens at 640 × 480 for its own tracking and leaves it that way. Returns how long each step
  /// took, for the diagnostics.
  @discardableResult
  private func chooseFormat() throws -> String {
    guard let device else { return "no camera" }
    func ms(_ from: Double) -> Int { Int(((CACurrentMediaTime() - from) * 1000).rounded()) }
    func width(_ format: AVCaptureDevice.Format) -> Int32 {
      CMVideoFormatDescriptionGetDimensions(format.formatDescription).width
    }
    // 4:3 uses the whole sensor, so it sees the most up and down.
    let formats = device.formats.filter { format in
      let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      return size.width * 3 == size.height * 4
        && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
    }.sorted { width($0) < width($1) }
    // The smallest that is wide enough, or failing that the widest there is.
    let chosen = formats.first { width($0) >= Self.targetWidth } ?? formats.last
    var mark = CACurrentMediaTime()
    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }
    let locking = ms(mark)
    mark = CACurrentMediaTime()
    let changed = chosen != nil && device.activeFormat != chosen
    if let chosen, changed { device.activeFormat = chosen }
    let sizing = ms(mark)
    mark = CACurrentMediaTime()
    // Straight lines must stay straight for the stitcher's pinhole model.
    if device.isGeometricDistortionCorrectionSupported {
      device.isGeometricDistortionCorrectionEnabled = true
    }
    if device.isFocusModeSupported(.continuousAutoFocus) {
      device.focusMode = .continuousAutoFocus
    }
    let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
    wantedWidth = Int(size.width)
    return "format: lock \(locking) ms, size \(sizing) ms (changed: \(changed)), correction and focus \(ms(mark)) ms, now \(size.width)×\(size.height)"
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard !delivering, let image = CMSampleBufferGetImageBuffer(sampleBuffer),
      CVPixelBufferGetWidth(image) == wantedWidth
    else { return }
    let width = CVPixelBufferGetWidth(image)
    let height = CVPixelBufferGetHeight(image)
    var fx: Float = 0
    var fy: Float = 0
    var cx = Float(width) / 2
    var cy = Float(height) / 2
    if let data = CMGetAttachment(
      sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil)
      as? Data, data.count >= MemoryLayout<matrix_float3x3>.size
    {
      let k = data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
      fx = k[0][0]
      fy = k[1][1]
      cx = k[2][0]
      cy = k[2][1]
    }
    if fx <= 0, let device {
      // Without delivered intrinsics, fall back to the format's horizontal field of view.
      let format = device.activeFormat
      let degrees =
        device.isGeometricDistortionCorrectionEnabled
        ? format.geometricDistortionCorrectedVideoFieldOfView : format.videoFieldOfView
      fx = Float(width) / 2 / tan(degrees * .pi / 360)
      fy = fx
    }
    let frame = WideFrame(
      image: image, width: width, height: height, fx: fx, fy: fy, cx: cx, cy: cy,
      timestamp: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    delivering = true
    DispatchQueue.main.async {
      self.onFrame?(frame)
      self.queue.async { self.delivering = false }
    }
  }
}

/// Shows the whole 0.5× camera frame, centred.
final class WideCameraView: UIView {
  private let layerToShow: AVCaptureVideoPreviewLayer
  init(layer: AVCaptureVideoPreviewLayer) {
    layerToShow = layer
    super.init(frame: .zero)
    backgroundColor = .black
    self.layer.addSublayer(layer)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
  override func layoutSubviews() {
    super.layoutSubviews()
    layerToShow.frame = bounds
  }
}
