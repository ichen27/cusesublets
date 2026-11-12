#if DEBUG
  import ARKit
  import RoomPlan
  import SwiftUI

  // Local hardware validation uses its own capture directory and never calls the marketplace API.
  struct DeviceCaptureCheckView: View {
    @State private var capture = false
    @State private var hasTake = false
    @State private var archive: URL?
    @State private var streamArchive: URL?
    @State private var hasStream = false
    @State private var error = ""
    @State private var busy = false
    @State private var confirmDiscard = false
    @State private var spotCapture = false
    @State private var hasSpotTake = false
    @State private var spotArchive: URL?
    @State private var confirmSpotDiscard = false
    private let spotDraft = PhotoCaptureDraft(
      id: "device-check-spots", ownerId: "local-device-check",
      listingId: "local-device-check-spots", name: "Private spot check")
    private var spotFolder: URL {
      SpotTake.folder(owner: spotDraft.ownerId, listing: spotDraft.listingId)
    }
    private let draft = PhotoCaptureDraft(
      id: "device-check", ownerId: "local-device-check", listingId: "local-device-check",
      name: "Private device check")
    private var folder: URL {
      PhotoCaptureDraft.folder(owner: draft.ownerId, listing: draft.listingId)
    }
    var body: some View {
      Form {
        Section("Local hardware test") {
          Text(
            "This development-only screen saves a private camera take on this iPhone. It does not need an account, contact the reconstruction service, or publish a listing."
          )
          Text(
            "Use an empty test room without people or private papers. Exporting creates a copy outside this app; delete that copy separately when finished."
          )
          LabeledContent(
            "Photographic capture",
            value: ARWorldTrackingConfiguration.isSupported ? "Available" : "Unavailable")
          LabeledContent(
            "LiDAR room layouts",
            value: RoomCaptureSession.isSupported ? "Available" : "Unavailable")
          Text(
            "The regular iPhone 17 supports the photographic test; LiDAR layout capture needs a supported Pro device."
          )
        }
        Section("Capture and recovery") {
          if hasTake {
            Text(
              "A local take was recovered. At least 30 stable views are needed to export; aim for 60 or more."
            )
            Button("Prepare private capture archive") { Task { await prepareArchive() } }
              .disabled(busy)
            if let archive {
              ShareLink("Export private capture archive", item: archive)
            }
            if hasStream {
              Text(
                "This take also recorded a camera stream: a small frame every 0.2 s with camera motion, exposure and why each frame was or was not saved. It is for offline testing and is never uploaded."
              )
              Button("Prepare camera stream recording") { Task { await prepareStream() } }
                .disabled(busy)
              if let streamArchive {
                ShareLink("Export camera stream recording", item: streamArchive)
              }
            }
            Button("Discard local take", role: .destructive) { confirmDiscard = true }
              .disabled(busy)
          } else {
            Button("Start camera test") { capture = true }
              .disabled(!ARWorldTrackingConfiguration.isSupported)
          }
          if busy { ProgressView("Preparing archive…") }
          if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
        Section("Spot capture") {
          Text(
            "Stand at a spot and turn in place, lining the circle up with each dot. Capture a few spots around the room, then review them. Nothing is uploaded from this screen."
          )
          if hasSpotTake {
            Text("A local spot take is saved on this iPhone.")
            Button("Review spot take") { spotCapture = true }.disabled(busy)
            Button("Prepare spot capture archive") { Task { await prepareSpotArchive() } }
              .disabled(busy)
            if let spotArchive {
              ShareLink("Export spot capture archive", item: spotArchive)
            }
            Button("Discard spot take", role: .destructive) { confirmSpotDiscard = true }
              .disabled(busy)
          } else {
            Button("Start spot capture") { spotCapture = true }
              .disabled(!ARWorldTrackingConfiguration.isSupported)
          }
        }
      }
      .navigationTitle("Device capture check")
      .task { recover() }
      .fullScreenCover(isPresented: $capture, onDismiss: recover) {
        PhotoCaptureScreen(recorder: PhotoRecorder(draft: draft, recordStream: true))
      }
      .fullScreenCover(isPresented: $spotCapture, onDismiss: recover) {
        SpotCaptureScreen(recorder: SpotRecorder(draft: spotDraft)) { archive in
          spotArchive = archive
        }
      }
      .confirmationDialog("Discard this private spot take?", isPresented: $confirmSpotDiscard) {
        Button("Discard", role: .destructive) {
          do {
            try FileManager.default.removeItem(at: spotFolder)
            spotArchive = nil
            recover()
          } catch { self.error = error.localizedDescription }
        }
      } message: {
        Text("This removes the local spot images and archive. Exported copies remain where you saved them.")
      }
      .confirmationDialog("Discard this private test take?", isPresented: $confirmDiscard) {
        Button("Discard", role: .destructive) {
          do {
            try FileManager.default.removeItem(at: folder)
            archive = nil
            streamArchive = nil
            error = ""
            recover()
          } catch { self.error = error.localizedDescription }
        }
      } message: {
        Text(
          "This removes the local source images, camera stream and archives. Exported copies remain where you saved them."
        )
      }
    }
    private func recover() {
      hasTake = FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("draft.json").path)
      hasStream = hasTake && StreamRecorder.exists(in: folder)
      hasSpotTake = FileManager.default.fileExists(
        atPath: spotFolder.appendingPathComponent("draft.json").path)
    }
    private func prepareSpotArchive() async {
      guard !busy else { return }
      busy = true
      error = ""
      defer { busy = false }
      do {
        let folder = spotFolder
        spotArchive = try await Task.detached(priority: .userInitiated) {
          try SpotTake.package(folder: folder)
        }.value
      } catch { self.error = error.localizedDescription }
    }
    private func prepareStream() async {
      guard !busy else { return }
      busy = true
      error = ""
      defer { busy = false }
      do {
        let folder = self.folder
        streamArchive = try await Task.detached(priority: .userInitiated) {
          try StreamRecorder.package(take: folder)
        }.value
      } catch { self.error = error.localizedDescription }
    }
    private func prepareArchive() async {
      guard !busy else { return }
      busy = true
      error = ""
      defer { busy = false }
      do {
        let folder = self.folder
        archive = try await Task.detached(priority: .userInitiated) {
          try PhotoRecorder.package(folder: folder)
        }.value
      } catch { self.error = error.localizedDescription }
    }
  }
#endif
