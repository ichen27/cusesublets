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
struct TourMesh: Decodable {
  let method: String
  let views: Int
  let vertices: Int
  let triangles: Int
}
struct RoomTour: Decodable, Identifiable {
  let id: String
  let listingId: String
  let name: String
  let status: String
  /// `"splat"` (Gaussian walk-around) or `"spots"` (stitched 360s); older servers send none.
  let kind: String
  let published: Bool
  /// Gaussian display metadata; nil for spot tours, whose result is read by the web viewer.
  let result: TourResult?
  /// Number of stitched spots in a ready spot tour.
  let spotCount: Int
  /// A coloured room mesh, when processing built one.
  let mesh: TourMesh?
  let error: String?

  private struct SpotSummary: Decodable { let spots: [Ignored] }
  private struct Ignored: Decodable {}
  enum CodingKeys: String, CodingKey {
    case id, listingId, name, status, kind, published, result, mesh, error
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    listingId = try c.decode(String.self, forKey: .listingId)
    name = try c.decode(String.self, forKey: .name)
    status = try c.decode(String.self, forKey: .status)
    kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "splat"
    published = try c.decode(Bool.self, forKey: .published)
    if kind == "spots" {
      result = nil
      spotCount = (try? c.decodeIfPresent(SpotSummary.self, forKey: .result))??.spots.count ?? 0
    } else {
      result = try c.decodeIfPresent(TourResult.self, forKey: .result)
      spotCount = 0
    }
    mesh = try c.decodeIfPresent(TourMesh.self, forKey: .mesh)
    error = try c.decodeIfPresent(String.self, forKey: .error)
  }
}
struct ToursResponse: Decodable {
  let tours: [RoomTour]
  let captureEnabled: Bool
}
struct TourResponse: Decodable { let tour: RoomTour }
/// Sends a spot take saved on this iPhone to become a tour of a place, then removes the local
/// copy. The tour starts private; its owner publishes it after looking through it.
enum SpotTourUpload {
  @MainActor static func send(
    api: APIClient, listingID: String, draft: PhotoCaptureDraft, folder: URL
  ) async throws {
    try JSONEncoder().encode(draft).write(
      to: folder.appendingPathComponent("draft.json"),
      options: [.atomic, .completeFileProtection])
    let (file, size, hash) = try await Task.detached(priority: .userInitiated) {
      // Package every time: spots may have been deleted or redone since the last package.
      let file = try SpotTake.package(folder: folder)
      let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size > 0, size <= SpotTake.archiveLimit else {
        throw CaptureFailure.message("Capture exceeds 96 MB. Remove a spot and try again.")
      }
      let input = try FileHandle(forReadingFrom: file)
      defer { try? input.close() }
      var hash = SHA256()
      while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
        hash.update(data: bytes)
      }
      return (file, size, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }.value
    let route = "/api/listings/\(listingID)/tours"
    let _: TourResponse = try await api.post(
      route, ["id": draft.id, "name": draft.name, "size": size, "sha256": hash, "kind": "spots"])
    try await api.uploadCapture(route + "/\(draft.id)/upload", file: file)
    try FileManager.default.removeItem(at: folder)
  }
}
struct RoomToursView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.scenePhase) var scenePhase
  @Environment(\.dismiss) private var dismiss
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
  @State private var exportIsMesh = false
  var owner: Bool { state.user?.id == listing.ownerId }
  var folder: URL { SpotTake.folder(owner: listing.ownerId, listing: listing.id) }
  /// A walk-around take saved by an earlier build, which can only be discarded now.
  var legacyFolder: URL { PhotoCaptureDraft.folder(owner: listing.ownerId, listing: listing.id) }
  @State private var legacy = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "chevron.left")
          }
          .buttonStyle(.quadIcon).accessibilityLabel("Back")
          Text("360° tours").font(.title2.weight(.heavy)).accessibilityAddTraits(.isHeader)
        }
        .padding(.top, 4)
        Text(
          "Stand in a few spots in each room and turn once at each. Viewers get a 360° look at every spot. Photos may show seams, and the 3D overview is rough. A tour does not check a place or its measurements."
        )
        .font(.subheadline).foregroundStyle(Color.quadMuted)
        if owner { capturing }
        if legacy {
          card {
            Text(
              "An older walk-around take is saved on this iPhone. This version captures spots instead, so that take can only be discarded."
            )
            .font(.footnote).foregroundStyle(Color.quadMuted)
            Button("Discard older take", role: .destructive) {
              try? FileManager.default.removeItem(at: legacyFolder)
              legacy = false
            }
            .buttonStyle(QuadSecondaryButtonStyle(fill: .quadWell))
          }
        }
        if let local { saved(local) }
        ForEach(tours) { tour in tourCard(tour) }
        if tours.isEmpty && local == nil {
          Text("No tours shared yet.").font(.subheadline).foregroundStyle(Color.quadMuted)
        }
        if busy {
          HStack(spacing: 8) {
            ProgressView()
            Text("Working…").font(.footnote.weight(.semibold)).foregroundStyle(Color.quadMuted)
          }
        }
        if !error.isEmpty {
          Text(error).font(.subheadline).foregroundStyle(Color(quad: 0xB42318))
          Button("Reload tours") { Task { await load() } }.buttonStyle(.quadSecondary)
        }
        if let export {
          card {
            ShareLink("Share exported PLY", item: export).font(.subheadline.weight(.bold))
              .tint(.quadOrangeDeep)
            Text(
              exportIsMesh
                ? "A coloured triangle mesh in metres, Y up. It opens in Blender, MeshLab and most 3D tools. It is reconstructed from photographs, so expect holes and soft edges."
                : "Use a Gaussian-compatible viewer or Blender importer. This is not an editable wall mesh."
            )
            .font(.footnote).foregroundStyle(Color.quadMuted)
          }
        }
      }
      .padding(.horizontal, 16).padding(.bottom, 16)
    }
    .foregroundStyle(Color.quadInk)
    .background(Color.quadGround.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)

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
        SpotCaptureScreen(recorder: SpotRecorder(draft: draft))
      }
      .alert("Discard this scan?", isPresented: $discard) {
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
  // MARK: Parts

  private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) { content() }
      .padding(16).frame(maxWidth: .infinity, alignment: .leading).quadCard(radius: 22)
  }

  @ViewBuilder private var capturing: some View {
    card {
      if enabled && ARWorldTrackingConfiguration.isSupported {
        Button("Capture spots for a tour", systemImage: "camera.viewfinder") {
          capture = PhotoCaptureDraft(
            id: UUID().uuidString, ownerId: listing.ownerId, listingId: listing.id, name: "Room")
        }
        .buttonStyle(.quadPrimaryWide).disabled(local != nil || busy)
      } else {
        Text(
          enabled
            ? "This device cannot scan. You can still look through the tours here."
            : "Tours cannot be built on this server yet."
        )
        .font(.subheadline.weight(.semibold))
      }
      Text(
        "Put away papers, photos and screens first. A scan uploads privately, and you choose whether it goes on your listing. It works without LiDAR on supported iPhones."
      )
      .font(.footnote).foregroundStyle(Color.quadMuted)
    }
  }

  private func saved(_ local: PhotoCaptureDraft) -> some View {
    card {
      HStack {
        Text("Your scan").font(.headline.weight(.heavy))
        Spacer()
        QuadChip(text: "On this iPhone · private")
      }
      SavedCapturePhotos(folder: folder)
      Button("Review spots") { capture = local }.buttonStyle(.quadSecondary).disabled(busy)
      VStack(alignment: .leading, spacing: 6) {
        Text("Tour name").font(.caption.weight(.bold)).foregroundStyle(Color.quadMuted)
        TextField("Tour name", text: $name).modifier(QuadFieldBox())
      }
      Text("What happens next").font(.subheadline.weight(.heavy)).padding(.top, 4)
      step(1, "Upload.", "Up to 96 MB. Keep the app open. If it is interrupted, upload the same scan again; nothing is built twice.")
      step(2, "We build the tour.", "You can leave this screen while it is built.")
      step(3, "You check it.", "It stays private until you add it to your listing.")
      Button("Upload and build the tour") { Task { await upload(local) } }
        .buttonStyle(.quadPrimaryWide)
        .disabled(busy || !enabled || name.trimmingCharacters(in: .whitespaces).isEmpty)
      Button("Discard this scan", role: .destructive) { discard = true }
        .buttonStyle(QuadSecondaryButtonStyle(wide: true, fill: .quadWell)).disabled(busy)
    }
  }

  private func step(_ number: Int, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text("\(number)").font(.caption.weight(.heavy)).foregroundStyle(Color.quadGreenText)
        .frame(width: 24, height: 24).background(Color.quadGreenTint, in: Circle())
        .accessibilityHidden(true)
      (Text(title + " ").font(.footnote.weight(.heavy))
        + Text(text).font(.footnote).foregroundColor(.quadMuted))
    }
  }

  private func tourCard(_ tour: RoomTour) -> some View {
    card {
      HStack {
        Text(tour.name).font(.headline.weight(.heavy))
        Spacer()
        QuadChip(
          text: tour.published ? "On your listing" : "Private",
          kind: tour.published ? .good : .plain)
      }
      if tour.status == "ready" {
        if tour.kind == "spots" {
          Text(tour.spotCount == 1 ? "1 spot" : "\(tour.spotCount) spots").font(.footnote)
            .foregroundStyle(Color.quadMuted)
        }
        NavigationLink(tour.kind == "spots" ? "Open 360° tour" : "Explore photographic tour") {
          TourWebView(api: state.api, listingID: listing.id, tourID: tour.id).navigationTitle(
            tour.name
          ).navigationBarTitleDisplayMode(.inline)
        }
        .buttonStyle(.quadDark)
        if tour.kind == "spots" {
          if owner && !tour.published {
            Text(
              "Check it before it goes on your listing: open the tour, visit every spot and look around for papers, photos and screens."
            )
            .font(.footnote).foregroundStyle(Color.quadMuted)
          }
        } else {
          Button("Export Gaussian PLY") { Task { await download(tour) } }
            .buttonStyle(.quadSecondary).disabled(busy)
        }
        if tour.mesh != nil {
          Button("Export room mesh (PLY)") { Task { await download(tour, mesh: true) } }
            .buttonStyle(.quadSecondary).disabled(busy)
            .accessibilityIdentifier("export-room-mesh")
        }
        if owner {
          if tour.published {
            Button("Take tour off my listing") {
              Task { await action(tour, "visibility", ["published": false]) }
            }
            .buttonStyle(QuadSecondaryButtonStyle(wide: true, fill: .quadWell)).disabled(busy)
          } else {
            Button("Add tour to my listing") {
              Task { await action(tour, "visibility", ["published": true]) }
            }
            .buttonStyle(.quadPrimaryWide).disabled(busy)
          }
        }
      } else {
        Text(status(tour)).font(.subheadline).foregroundStyle(Color.quadMuted)
        if owner && tour.status == "failed" {
          Button("Try building it again") { Task { await action(tour, "retry") } }
            .buttonStyle(.quadSecondary).disabled(busy)
        }
        if owner && tour.status == "uploading" && local?.id != tour.id {
          Text(
            "The original scan is still needed. Upload it again from the iPhone that made it, or delete this entry."
          )
          .font(.footnote).foregroundStyle(Color.quadMuted)
        }
      }
      if owner {
        Button("Delete tour", role: .destructive) { deleting = tour }
          .font(.subheadline.weight(.bold)).foregroundStyle(Color(quad: 0xB42318))
          .disabled(busy)
      }
    }
  }

  func status(_ tour: RoomTour) -> String {
    switch tour.status {
    case "uploading": return "Waiting for the scan to upload"
    case "queued": return "Waiting to be built"
    case "processing": return "Building the tour. You can leave this screen."
    case "deleting":
      return "Deletion is pending. Tap Delete tour again to finish removing its files."
    case "failed": return tour.error ?? "The tour could not be built. Try again."
    default: return tour.status
    }
  }
  func recover() {
    guard owner else {
      local = nil
      return
    }
    legacy = FileManager.default.fileExists(
      atPath: legacyFolder.appendingPathComponent("draft.json").path)
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
      error = ""
    } catch { self.error = error.localizedDescription }
  }
  func upload(_ draft: PhotoCaptureDraft) async {
    busy = true
    defer { busy = false }
    do {
      var draft = draft
      draft.name = name.trimmingCharacters(in: .whitespaces)
      local = draft
      try await SpotTourUpload.send(
        api: state.api, listingID: listing.id, draft: draft, folder: folder)
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
  func download(_ tour: RoomTour, mesh: Bool = false) async {
    busy = true
    defer { busy = false }
    do {
      export = try await state.api.download(
        "/api/listings/\(listing.id)/tours/\(tour.id)/\(mesh ? "mesh" : "model")",
        name: mesh ? "room-mesh.ply" : "room.ply")
      exportIsMesh = mesh
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
    }.quadSidewaysScroll().task {
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
