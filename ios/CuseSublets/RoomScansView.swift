import AVFoundation
import RoomPlan
import SceneKit
import SwiftUI
import simd

struct LocalRoomDraft: Codable, Identifiable {
  let id: String
  let ownerId: String
  let listingId: String
  var name: String
  let layout: RoomLayout
}
struct RoomScansView: View {
  @EnvironmentObject var state: AppState
  let listing: Listing
  @State private var scans: [RoomScan] = []
  @State private var capture = false
  @State private var local: LocalRoomDraft?
  @State private var name = "Room"
  @State private var error = ""
  @State private var busy = false
  @State private var deleting: RoomScan?
  var owner: Bool { state.user?.id == listing.ownerId }
  var draftURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("room-drafts", isDirectory: true).appendingPathComponent(
        "\(listing.ownerId)-\(listing.id).json")
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("Room layouts").font(.largeTitle.bold())
        Text(
          "Approximate geometry captured on an iPhone. Furniture is simplified; this is not a photographic tour or a measured survey."
        ).foregroundStyle(.secondary)
        if owner {
          if RoomCaptureSession.isSupported {
            Button("Scan a room", systemImage: "viewfinder") {
              Task {
                if await AVCaptureDevice.requestAccess(for: .video) {
                  capture = true
                } else {
                  error = "Camera access is off. Enable it for CuseSublets in Settings."
                }
              }
            }.buttonStyle(.borderedProminent).disabled(busy || local != nil)
          } else {
            Label("Room scanning needs a LiDAR-equipped iPhone.", systemImage: "info.circle")
            Text("You can still upload photos, videos and an existing tour from Manage place.")
              .font(.caption)
          }
          Text(
            "Scans stay private until you explicitly publish them. Check for private information before sharing."
          ).font(.caption)
        }
        if let draft = local {
          Text("Private scan — saved on this iPhone").font(.headline)
          RoomModelView(layout: draft.layout).frame(height: 320)
          TextField("Room name", text: $name).textFieldStyle(.roundedBorder)
          HStack {
            Button("Upload privately") { Task { await upload(draft) } }.buttonStyle(
              .borderedProminent
            ).disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Discard", role: .destructive) {
              do {
                try FileManager.default.removeItem(at: draftURL)
                local = nil
              } catch { self.error = error.localizedDescription }
            }.disabled(busy)
          }
        }
        ForEach(scans) { scan in
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(scan.name).font(.headline)
              Spacer()
              StatusText(text: scan.published ? "Published" : "Private")
            }
            RoomModelView(layout: scan.layout).frame(height: 300)
            Text("Drag to orbit · pinch to zoom").font(.caption).foregroundStyle(.secondary)
            if owner {
              HStack {
                Button(scan.published ? "Hide from listing" : "Publish to listing") {
                  Task { await visibility(scan) }
                }.disabled(busy)
                Spacer()
                Button("Delete", role: .destructive) { deleting = scan }.disabled(busy)
              }
            }
          }
        }
        if scans.isEmpty && local == nil {
          Text("No room layouts shared yet.").foregroundStyle(.secondary)
        }
        if busy { ProgressView() }
        if !error.isEmpty {
          Text(error).foregroundStyle(.red)
          Button("Reload scans") { Task { await load() } }
        }
      }.padding()
    }.navigationTitle("Room capture").navigationBarTitleDisplayMode(.inline).task {
      await load()
      if owner {
        do {
          if FileManager.default.fileExists(atPath: draftURL.path) {
            let draft = try JSONDecoder().decode(
              LocalRoomDraft.self, from: Data(contentsOf: draftURL))
            if draft.ownerId == state.user?.id && draft.listingId == listing.id {
              local = draft
              name = draft.name
            }
          }
        } catch { self.error = "Could not reopen your private scan: " + error.localizedDescription }
      }
    }
    .fullScreenCover(isPresented: $capture) {
      RoomCaptureScreen { result in
        capture = false
        switch result {
        case .success(let layout):
          do {
            let draft = LocalRoomDraft(
              id: UUID().uuidString, ownerId: listing.ownerId, listingId: listing.id, name: "Room",
              layout: layout)
            try FileManager.default.createDirectory(
              at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(draft).write(
              to: draftURL, options: [.atomic, .completeFileProtection])
            local = draft
            name = "Room"
          } catch { self.error = "Could not save this scan: " + error.localizedDescription }
        case .failure(let e): error = e.localizedDescription
        }
      }
    }
    .alert(
      "Delete this room scan?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    ) {
      Button("Delete", role: .destructive) {
        if let scan = deleting {
          Task {
            do {
              try await state.api.act("/api/listings/\(listing.id)/scans/\(scan.id)/delete")
              await load()
            } catch { self.error = error.localizedDescription }
          }
        }
        deleting = nil
      }
      Button("Cancel", role: .cancel) { deleting = nil }
    } message: {
      Text("This removes it from the listing and your account.")
    }
  }
  func load() async {
    do {
      let r: ScansResponse = try await state.api.get("/api/listings/\(listing.id)/scans")
      scans = r.scans
      error = ""
    } catch { self.error = error.localizedDescription }
  }
  func upload(_ draft: LocalRoomDraft) async {
    busy = true
    defer { busy = false }
    do {
      var saved = draft
      saved.name = name
      try JSONEncoder().encode(saved).write(
        to: draftURL, options: [.atomic, .completeFileProtection])
      local = saved
      try await state.api.act(
        "/api/listings/\(listing.id)/scans",
        ["id": saved.id, "name": saved.name, "layout": try saved.layout.dictionary()])
      try FileManager.default.removeItem(at: draftURL)
      local = nil
      await load()
    } catch { self.error = error.localizedDescription }
  }
  func visibility(_ scan: RoomScan) async {
    busy = true
    defer { busy = false }
    do {
      try await state.api.act(
        "/api/listings/\(listing.id)/scans/\(scan.id)/visibility", ["published": !scan.published])
      await load()
    } catch { self.error = error.localizedDescription }
  }
}
struct RoomModelView: UIViewRepresentable {
  let layout: RoomLayout
  func makeUIView(context: Context) -> SCNView {
    let view = SCNView()
    view.allowsCameraControl = true
    view.autoenablesDefaultLighting = true
    view.backgroundColor = UIColor.secondarySystemBackground
    view.accessibilityLabel = "Approximate three-dimensional room layout"
    update(view)
    return view
  }
  func updateUIView(_ view: SCNView, context: Context) { update(view) }
  func update(_ view: SCNView) {
    let scene = SCNScene()
    for e in layout.elements where e.dimensions.count == 3 && e.transform.count == 16 {
      let d = e.dimensions
      let box = SCNBox(
        width: CGFloat(max(d[0], 0.04)), height: CGFloat(max(d[1], 0.04)),
        length: CGFloat(max(d[2], 0.04)), chamferRadius: 0)
      box.firstMaterial?.diffuse.contents =
        e.kind == "object"
        ? UIColor.systemGray3
        : (e.kind == "wall"
          ? UIColor.systemOrange.withAlphaComponent(0.65)
          : UIColor.systemTeal.withAlphaComponent(0.55))
      box.firstMaterial?.isDoubleSided = true
      let t = e.transform
      let node = SCNNode(geometry: box)
      node.simdTransform = simd_float4x4(
        columns: (
          SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]),
          SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15])
        ))
      scene.rootNode.addChildNode(node)
    }
    view.scene = scene
  }
}
struct RoomCaptureScreen: View {
  @Environment(\.dismiss) var dismiss
  let completion: (Result<RoomLayout, Error>) -> Void
  @State private var finish = false
  var body: some View {
    ZStack(alignment: .bottom) {
      CaptureSurface(finish: $finish, completion: completion).ignoresSafeArea()
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        if finish {
          ProgressView("Processing room…")
        } else {
          Button("Finish scan") { finish = true }.buttonStyle(.borderedProminent)
        }
      }.padding().background(.regularMaterial)
    }.interactiveDismissDisabled()
  }
}
struct CaptureSurface: UIViewRepresentable {
  @Binding var finish: Bool
  let completion: (Result<RoomLayout, Error>) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
  func makeUIView(context: Context) -> RoomCaptureView {
    let view = RoomCaptureView(frame: .zero)
    view.delegate = context.coordinator
    view.captureSession.run(configuration: .init())
    return view
  }
  func updateUIView(_ view: RoomCaptureView, context: Context) {
    if finish && !context.coordinator.stopping {
      context.coordinator.stopping = true
      view.captureSession.stop()
    }
  }
  static func dismantleUIView(_ view: RoomCaptureView, coordinator: Coordinator) {
    coordinator.cancelled = true
    view.captureSession.stop()
  }
  @objc(CuseRoomCaptureCoordinator)
  @MainActor final class Coordinator: NSObject, @preconcurrency RoomCaptureViewDelegate {
    nonisolated required init?(coder: NSCoder) { return nil }
    nonisolated func encode(with coder: NSCoder) {}
    let completion: (Result<RoomLayout, Error>) -> Void
    var stopping = false, cancelled = false
    init(completion: @escaping (Result<RoomLayout, Error>) -> Void) { self.completion = completion }
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
      if let error, !cancelled {
        completion(.failure(error))
        return false
      }
      return !cancelled
    }
    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
      guard !cancelled else { return }
      if let error {
        completion(.failure(error))
        return
      }
      func element(_ kind: String, _ dimensions: SIMD3<Float>, _ t: simd_float4x4) -> RoomElement {
        RoomElement(
          kind: kind, dimensions: [dimensions.x, dimensions.y, dimensions.z],
          transform: [t.columns.0, t.columns.1, t.columns.2, t.columns.3].flatMap {
            [$0.x, $0.y, $0.z, $0.w]
          })
      }
      let room = processedResult
      var elements = room.walls.map { element("wall", $0.dimensions, $0.transform) }
      elements += room.doors.map { element("door", $0.dimensions, $0.transform) }
      elements += room.windows.map { element("window", $0.dimensions, $0.transform) }
      elements += room.openings.map { element("opening", $0.dimensions, $0.transform) }
      elements += room.objects.map { element("object", $0.dimensions, $0.transform) }
      guard !room.walls.isEmpty, elements.count <= 300 else {
        completion(
          .failure(
            APIError(
              message: "Capture a room with at least one wall and no more than 300 elements.")))
        return
      }
      completion(.success(RoomLayout(elements: elements)))
    }
  }
}
