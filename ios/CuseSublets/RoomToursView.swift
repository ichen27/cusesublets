import ARKit
import CryptoKit
import ImageIO
import SwiftUI
import WebKit

struct TourCamera: Decodable {
  let position: [Double]
  let target: [Double]
  let up: [Double]
}
struct TourResult: Decodable {
  let method: String
  let views: Int
  let gaussians: Int
  let camera: TourCamera
}
struct RoomTour: Decodable, Identifiable {
  let id: String
  let listingId: String
  let name: String
  let status: String
  let published: Bool
  let result: TourResult?
  let error: String?
}
struct ToursResponse: Decodable {
  let tours: [RoomTour]
  let captureEnabled: Bool
}
struct TourResponse: Decodable { let tour: RoomTour }
struct RoomToursView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.scenePhase) var scenePhase
  let listing: Listing
  @State private var tours: [RoomTour] = []
  @State private var enabled = false
  @State private var local: PhotoCaptureDraft?
  @State private var capture: PhotoCaptureDraft?
  @State private var name = "Room"
  @State private var error = ""
  @State private var busy = false
  @State private var discard = false
  @State private var deleting: RoomTour?
  @State private var export: URL?
  var owner: Bool { state.user?.id == listing.ownerId }
  var folder: URL { PhotoCaptureDraft.folder(owner: listing.ownerId, listing: listing.id) }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("Photographic tours").font(.largeTitle.bold())
        Text(
          "Capture overlapping camera views, then reconstruct a Gaussian tour. Results may have gaps, blur and distorted surfaces. These tours do not verify a property or its dimensions."
        ).foregroundStyle(.secondary)
        if owner {
          if enabled && ARWorldTrackingConfiguration.isSupported {
            Button("Capture a photographic tour", systemImage: "camera.viewfinder") {
              capture = PhotoCaptureDraft(
                id: UUID().uuidString, ownerId: listing.ownerId, listingId: listing.id, name: "Room"
              )
            }.buttonStyle(.borderedProminent).disabled(local != nil || busy)
          } else {
            Text(
              enabled
                ? "Camera capture is unavailable on this device. You can review existing tours here."
                : "Photographic processing is not configured on this server yet.")
          }
          Text(
            "Remove personal papers and faces from view. Captures upload privately; you choose whether to publish the result. Camera-only capture works without LiDAR on supported iPhones."
          ).font(.caption)
        }
        if let local {
          Text("Saved on this iPhone · private").font(.headline)
          SavedCapturePhotos(folder: folder)
          TextField("Room name", text: $name).textFieldStyle(.roundedBorder)
          Text(
            "Upload up to 64 MB. Keep the app open during upload. If interrupted, retry the same saved take; the server prevents duplicate jobs."
          ).font(.caption)
          HStack {
            Button("Upload and reconstruct") { Task { await upload(local) } }.buttonStyle(
              .borderedProminent
            ).disabled(busy || !enabled || name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Discard take", role: .destructive) { discard = true }.disabled(busy)
          }
        }
        ForEach(tours) { tour in
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(tour.name).font(.headline)
              Spacer()
              StatusText(text: tour.published ? "Published" : "Private")
            }
            if tour.status == "ready" {
              NavigationLink("Explore photographic tour") {
                TourWebView(api: state.api, listingID: listing.id, tourID: tour.id).navigationTitle(
                  tour.name
                ).navigationBarTitleDisplayMode(.inline)
              }
              Button("Export Gaussian PLY") { Task { await download(tour) } }.disabled(busy)
              if owner {
                Button(tour.published ? "Hide from listing" : "Publish to listing") {
                  Task { await action(tour, "visibility", ["published": !tour.published]) }
                }.disabled(busy)
              }
            } else {
              Text(status(tour)).foregroundStyle(.secondary)
              if owner && tour.status == "failed" {
                Button("Retry reconstruction") { Task { await action(tour, "retry") } }.disabled(
                  busy)
              }
              if owner && tour.status == "uploading" && local?.id != tour.id {
                Text(
                  "The original take is still needed. Retry from the iPhone that captured it, or delete this entry."
                ).font(.caption)
              }
            }
            if owner {
              Button("Delete tour", role: .destructive) { deleting = tour }.disabled(busy)
            }
          }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        }
        if tours.isEmpty && local == nil {
          Text("No photographic tours shared yet.").foregroundStyle(.secondary)
        }
        if busy { ProgressView("Working…") }
        if !error.isEmpty {
          Text(error).foregroundStyle(.red)
          Button("Reload tours") { Task { await load() } }
        }
        if let export {
          ShareLink("Share exported PLY", item: export)
          Text(
            "Use a Gaussian-compatible viewer or Blender importer. This is not an editable wall mesh."
          ).font(.caption)
        }
      }.padding()
    }.navigationTitle("Photographic tours").navigationBarTitleDisplayMode(.inline)
      .task {
        await load()
        recover()
      }
      .task(id: scenePhase) {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(8))
          if Task.isCancelled { return }
          await load()
        }
      }
      .fullScreenCover(item: $capture, onDismiss: { recover() }) { draft in
        PhotoCaptureScreen(recorder: PhotoRecorder(draft: draft))
      }
      .alert("Discard this saved take?", isPresented: $discard) {
        Button("Discard", role: .destructive) {
          do {
            try FileManager.default.removeItem(at: folder)
            local = nil
          } catch { self.error = error.localizedDescription }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This removes the camera images stored on this iPhone.")
      }
      .alert(
        "Delete this tour and its capture?",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
      ) {
        Button("Delete", role: .destructive) {
          if let tour = deleting { Task { await action(tour, "delete") } }
          deleting = nil
        }
        Button("Cancel", role: .cancel) { deleting = nil }
      } message: {
        Text(
          "The server will remove its private capture and reconstructed model. A copy already downloaded by someone else cannot be revoked."
        )
      }
  }
  func status(_ tour: RoomTour) -> String {
    switch tour.status {
    case "uploading": return "Waiting for capture upload"
    case "queued": return "Queued for reconstruction"
    case "processing": return "Reconstructing the room. You can leave this screen."
    case "failed": return tour.error ?? "Reconstruction failed. Try again."
    default: return tour.status
    }
  }
  func recover() {
    guard owner else {
      local = nil
      return
    }
    do {
      let file = folder.appendingPathComponent("draft.json")
      guard FileManager.default.fileExists(atPath: file.path) else {
        local = nil
        return
      }
      let draft = try JSONDecoder().decode(PhotoCaptureDraft.self, from: Data(contentsOf: file))
      guard draft.ownerId == state.user?.id && draft.listingId == listing.id else { return }
      local = draft
      name = draft.name
    } catch { self.error = "Could not reopen the saved take: " + error.localizedDescription }
  }
  func load() async {
    do {
      let r: ToursResponse = try await state.api.get("/api/listings/\(listing.id)/tours")
      tours = r.tours
      enabled = r.captureEnabled
    } catch { self.error = error.localizedDescription }
  }
  func upload(_ draft: PhotoCaptureDraft) async {
    busy = true
    defer { busy = false }
    do {
      var draft = draft
      draft.name = name.trimmingCharacters(in: .whitespaces)
      try JSONEncoder().encode(draft).write(
        to: folder.appendingPathComponent("draft.json"),
        options: [.atomic, .completeFileProtection])
      local = draft
      let folder = self.folder
      let (file, size, hash) = try await Task.detached(priority: .userInitiated) {
        let file = folder.appendingPathComponent("room.roomcapture")
        if !FileManager.default.fileExists(atPath: file.path) {
          _ = try PhotoRecorder.package(folder: folder)
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 64 * 1024 * 1024 else {
          throw CaptureFailure.message("Capture exceeds 64 MB. Discard and capture a smaller room.")
        }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
          hash.update(data: bytes)
        }
        return (file, size, hash.finalize().map { String(format: "%02x", $0) }.joined())
      }.value
      let route = "/api/listings/\(listing.id)/tours"
      let _: TourResponse = try await state.api.post(
        route, ["id": draft.id, "name": draft.name, "size": size, "sha256": hash])
      try await state.api.uploadCapture(route + "/\(draft.id)/upload", file: file)
      try FileManager.default.removeItem(at: folder)
      local = nil
      error = ""
      await load()
    } catch { self.error = error.localizedDescription }
  }
  func action(_ tour: RoomTour, _ action: String, _ body: [String: Any] = [:]) async {
    busy = true
    defer { busy = false }
    do {
      try await state.api.act("/api/listings/\(listing.id)/tours/\(tour.id)/\(action)", body)
      error = ""
      await load()
    } catch { self.error = error.localizedDescription }
  }
  func download(_ tour: RoomTour) async {
    busy = true
    defer { busy = false }
    do {
      export = try await state.api.download(
        "/api/listings/\(listing.id)/tours/\(tour.id)/model", name: "room.ply")
    } catch { self.error = error.localizedDescription }
  }
}
extension PhotoCaptureDraft: Identifiable {}
struct SavedCapturePhotos: View {
  let folder: URL
  @State private var files: [URL] = []
  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack {
        ForEach(files, id: \.lastPathComponent) { file in
          if let image = thumbnail(file) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: 180, height: 130)
              .accessibilityLabel("Private saved camera view")
          }
        }
      }
    }.task {
      files =
        ((try? FileManager.default.contentsOfDirectory(
          at: folder.appendingPathComponent("images"), includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
  }
}
private func thumbnail(_ file: URL) -> UIImage? {
  guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
    let image = CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 360,
      ] as CFDictionary)
  else { return nil }
  return UIImage(cgImage: image)
}
struct TourWebView: UIViewRepresentable {
  let api: APIClient
  let listingID: String
  let tourID: String
  func makeCoordinator() -> Coordinator { Coordinator(base: api.baseURL) }
  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .zero, configuration: config)
    web.navigationDelegate = context.coordinator
    var url = URLComponents(
      url: api.baseURL.appendingPathComponent("tour-viewer"), resolvingAgainstBaseURL: false)!
    url.queryItems = [
      URLQueryItem(name: "listing", value: listingID), URLQueryItem(name: "tour", value: tourID),
    ]
    let target = url.url!
    Task { @MainActor [weak web] in
      if let cookie = api.webSessionCookie() {
        await config.websiteDataStore.httpCookieStore.setCookie(cookie)
      }
      web?.load(URLRequest(url: target))
    }
    return web
  }
  func updateUIView(_ uiView: WKWebView, context: Context) {}
  static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
    view.stopLoading()
    view.loadHTMLString("", baseURL: nil)
    view.navigationDelegate = nil
  }
  final class Coordinator: NSObject, WKNavigationDelegate {
    let base: URL
    init(base: URL) { self.base = base }
    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url, url.scheme == base.scheme,
        url.host == base.host, url.port == base.port, url.path == "/tour-viewer"
      else {
        decisionHandler(.cancel)
        return
      }
      decisionHandler(.allow)
    }
  }
}
