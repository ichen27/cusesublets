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
  static let targetWidth: Int32 = 1920

  let previewLayer = AVCaptureVideoPreviewLayer()
  /// Called on the main queue for each delivered frame.
  var onFrame: ((WideFrame) -> Void)?

  private let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "cuse.wide-camera")
  private var device: AVCaptureDevice?
  private var configured = false
  private var delivering = false

  static var isAvailable: Bool {
    AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil
  }

  override init() {
    super.init()
    previewLayer.session = session
    previewLayer.videoGravity = .resizeAspectFill
  }

  /// Starts the camera; `completion` gets an error message, or nil once frames are flowing.
  func start(completion: @escaping (String?) -> Void) {
    queue.async {
      do {
        try self.configure()
        try self.chooseFormat()
        self.session.startRunning()
        DispatchQueue.main.async {
          if let connection = self.previewLayer.connection,
            connection.isVideoRotationAngleSupported(90)
          {
            connection.videoRotationAngle = 90
          }
          completion(self.session.isRunning ? nil : "The 0.5× camera could not start.")
        }
      } catch {
        DispatchQueue.main.async { completion(error.localizedDescription) }
      }
    }
  }

  func stop(completion: (() -> Void)? = nil) {
    queue.async {
      if self.session.isRunning { self.session.stopRunning() }
      self.unlockExposure()
      if let completion { DispatchQueue.main.async(execute: completion) }
    }
  }

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

  /// Sets the camera's format before every start, not once: between turns ARKit runs this
  /// same lens at 640 × 480 for its own tracking and leaves it that way.
  private func chooseFormat() throws {
    guard let device else { return }
    // The smallest 4:3 format at least 1920 wide: enough for a 4096-wide panorama.
    let formats = device.formats.filter { format in
      let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      return size.width * 3 == size.height * 4 && size.width >= Self.targetWidth
        && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
    }.sorted {
      CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
        < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
    }
    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }
    if let format = formats.first, device.activeFormat != format { device.activeFormat = format }
    // Straight lines must stay straight for the stitcher's pinhole model.
    if device.isGeometricDistortionCorrectionSupported {
      device.isGeometricDistortionCorrectionEnabled = true
    }
    if device.isFocusModeSupported(.continuousAutoFocus) {
      device.focusMode = .continuousAutoFocus
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard !delivering, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
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

/// Shows the 0.5× camera full screen.
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
