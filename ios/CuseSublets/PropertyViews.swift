import SwiftUI
import WebKit
import simd

/// The scanning app's home: every property, and where to add one.
struct PropertiesView: View {
  @StateObject private var store = PropertyStore()
  @State private var naming = false
  @State private var newName = ""
  @State private var path: [String] = []

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if store.properties.isEmpty {
          ContentUnavailableView {
            Label("No properties yet", systemImage: "house")
          } description: {
            Text("Add a property, then scan it spot by spot to make a 360° tour.")
          } actions: {
            Button("Add a property") { naming = true }.buttonStyle(.borderedProminent)
              .tint(.cuseButtonFill)
          }
        } else {
          List {
            ForEach(store.properties) { property in
              NavigationLink(value: property.id) { PropertyRow(property: property) }
            }
            .onDelete { offsets in
              for index in offsets { store.remove(store.properties[index].id) }
            }
          }
        }
      }
      .navigationTitle("Properties")
      .task { StudioClient.rememberLaunchAddress() }
      .navigationDestination(for: String.self) { id in
        PropertyDetailView(store: store, id: id)
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          NavigationLink {
            StudioSettingsView()
          } label: {
            Label("Settings", systemImage: "gearshape")
          }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Add a property", systemImage: "plus") { naming = true }
        }
      }
      .alert("New property", isPresented: $naming) {
        TextField("Name or address", text: $newName).textInputAutocapitalization(.words)
        Button("Add") {
          let property = store.add(name: newName)
          newName = ""
          path = [property.id]
        }
        Button("Cancel", role: .cancel) { newName = "" }
      } message: {
        Text("For example the street address.")
      }
    }
  }
}

private struct PropertyRow: View {
  let property: Property
  var body: some View {
    let scanned = PropertyScan.spots(for: property.id).count
    VStack(alignment: .leading, spacing: 4) {
      Text(property.name).font(.headline)
      Text(
        property.uploaded
          ? "Tour generated"
          : scanned > 0 ? "\(scanned) spots scanned, not generated yet" : "Not scanned yet"
      ).font(.subheadline).foregroundStyle(.secondary)
    }
  }
}

/// What is saved on this iPhone for a property's scan.
enum PropertyScan {
  static func frames(for id: String) -> [CaptureFrameRecord] {
    (try? PhotoRecorder.savedFrames(in: PropertyStore.captureFolder(id))) ?? []
  }
  static func spots(for id: String) -> [SpotRecord] {
    SpotTake.savedSpots(in: PropertyStore.captureFolder(id), frames: frames(for: id))
  }
}

/// One property: scan it, generate its tour, and view the result.
struct PropertyDetailView: View {
  @ObservedObject var store: PropertyStore
  let id: String
  @Environment(\.dismiss) private var dismiss
  @State private var spots: [SpotRecord] = []
  @State private var patches: [Int: UIImage] = [:]
  /// A spot was dragged since the tour was last generated.
  @State private var moved = false
  @State private var remote: StudioProperty?
  @State private var scanning = false
  @State private var viewing = false
  @State private var working = ""
  @State private var problem = ""
  @State private var preview: SpotRecord?
  @State private var confirmRescan = false
  @State private var confirmDelete = false
  @State private var renaming = false
  @State private var name = ""

  private var property: Property? { store.properties.first { $0.id == id } }

  var body: some View {
    List {
      if !problem.isEmpty {
        Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
      }
      if !working.isEmpty {
        Section { ProgressView(working) }
      }
      tourSection
      if spots.isEmpty { guideSection } else { scanSection }
      Section {
        Button("Delete property", role: .destructive) { confirmDelete = true }
      }
    }
    .navigationTitle(property?.name ?? "Property").navigationBarTitleDisplayMode(.large)
    .toolbar {
      Button("Rename") {
        name = property?.name ?? ""
        renaming = true
      }
    }
    .task(id: id) { await refresh() }
    .task(id: remote?.status) {
      // Stitching takes well under a minute for a few spots; keep checking until it ends.
      while remote?.status == "processing", !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        await loadRemote()
      }
    }
    .fullScreenCover(isPresented: $scanning, onDismiss: { Task { await loadScan() } }) {
      if let property {
        SpotCaptureScreen(recorder: SpotRecorder(draft: PropertyStore.draft(for: property))) {
          archive in Task { await upload(archive) }
        }
      }
    }
    .fullScreenCover(isPresented: $viewing) {
      if let client = StudioClient.configured {
        StudioTourScreen(
          title: property?.name ?? "Tour", url: client.tourPage(id), cookie: client.tokenCookie)
      }
    }
    .sheet(item: $preview) { spot in
      NavigationStack {
        VStack(spacing: 0) {
          SpotPreview(
            folder: PropertyStore.captureFolder(id), spot: spot,
            frames: PropertyScan.frames(for: id))
          Text("Rough preview. The finished tour is stitched when you generate it.")
            .font(.caption).padding()
        }
        .navigationTitle("Spot \(spot.spot)").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Done") { preview = nil } }
      }
    }
    .confirmationDialog("Scan this property again?", isPresented: $confirmRescan) {
      Button("Discard this scan and start over", role: .destructive) {
        try? FileManager.default.removeItem(at: PropertyStore.captureFolder(id))
        spots = []
        patches = [:]
        moved = false
        scanning = true
      }
    } message: {
      Text("The scan on this iPhone is replaced. A generated tour stays until you generate again.")
    }
    .confirmationDialog("Delete this property?", isPresented: $confirmDelete) {
      Button("Delete property and its tour", role: .destructive) { Task { await delete() } }
    }
    .alert("Rename property", isPresented: $renaming) {
      TextField("Name or address", text: $name)
      Button("Save") { store.update(id) { $0.name = name } }
      Button("Cancel", role: .cancel) {}
    }
  }

  // MARK: Sections

  @ViewBuilder private var tourSection: some View {
    if let remote {
      Section("Tour") {
        switch remote.status {
        case "ready":
          Button {
            viewing = true
          } label: {
            Label("View 360° tour", systemImage: "view.360").font(.headline)
          }
          Text(
            "\(remote.spots) spots" + (remote.seconds.map { " · stitched in \(Int($0.rounded())) s" } ?? "")
          ).font(.subheadline).foregroundStyle(.secondary)
        case "processing":
          ProgressView("Stitching the tour…")
        default:
          Label(StudioClient.explain(remote.error ?? "unknown"), systemImage: "xmark.octagon")
            .foregroundStyle(.red)
        }
      }
    }
  }

  private var guideSection: some View {
    Section("Before you scan") {
      GuideStep(symbol: "lightbulb", text: "Turn on the lights and open the blinds.")
      GuideStep(symbol: "doc.text", text: "Put away personal papers, photos and screens.")
      GuideStep(
        symbol: "figure.stand",
        text: "Stand in the middle of a room. Each spot is one turn on the spot: six photos around you, with the phone upright and level.")
      GuideStep(
        symbol: "map",
        text: "Walk to the next spot with the phone up. Two or three spots cover most rooms; add one in each doorway.")
      Button {
        scanning = true
      } label: {
        Label("Start scan", systemImage: "camera.viewfinder").font(.headline)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent).tint(.cuseButtonFill).controlSize(.large)
    }
  }

  private var scanSection: some View {
    Section("Scan on this iPhone") {
      SpotMapCanvas(cells: [], spots: spots, you: nil, patches: patches, onMove: move)
        .frame(height: 280).listRowBackground(Color.black)
      Text(
        moved
          ? "Spot moved. Generate again to update the tour."
          : "A rough sketch of what each spot captured, from above. Drag a marker if a spot is in the wrong place."
      ).font(.footnote).foregroundStyle(moved ? Color.cuseOrange : .secondary)
      ForEach(spots, id: \.spot) { spot in
        HStack {
          Text("Spot \(spot.spot)")
          Spacer()
          Button("Preview 360") { preview = spot }.buttonStyle(.bordered)
        }
      }
      Button {
        Task { await generate() }
      } label: {
        Label(
          remote == nil ? "Generate tour" : "Generate again", systemImage: "sparkles"
        ).font(.headline).frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent).tint(.cuseButtonFill).controlSize(.large)
      .disabled(!working.isEmpty || remote?.status == "processing")
      Button("Scan again") { confirmRescan = true }.disabled(!working.isEmpty)
    }
  }

  // MARK: Actions

  private func refresh() async {
    await loadScan()
    await loadRemote()
  }

  /// Reads the scan saved on this iPhone and its floor pictures.
  private func loadScan() async {
    let id = self.id
    let scan = await Task.detached(priority: .userInitiated) {
      let frames = PropertyScan.frames(for: id)
      let spots = SpotTake.savedSpots(in: PropertyStore.captureFolder(id), frames: frames)
      return (
        spots,
        FloorPatch.load(folder: PropertyStore.captureFolder(id), spots: spots, frames: frames)
      )
    }.value
    spots = scan.0
    patches = scan.1
  }

  private func move(_ spot: Int, to place: SIMD2<Float>) {
    do {
      try SpotTake.moveSpot(spot, to: place, in: PropertyStore.captureFolder(id))
      spots = PropertyScan.spots(for: id)
      moved = true
      problem = ""
    } catch { problem = error.localizedDescription }
  }

  private func loadRemote() async {
    guard let client = StudioClient.configured else { return }
    do {
      remote = try await client.status(id)
      if remote != nil, property?.uploaded == false { store.update(id) { $0.uploaded = true } }
    } catch {
      // Not reaching the service only matters when the person asks for something from it.
    }
  }

  private func generate() async {
    problem = ""
    working = "Preparing the scan…"
    let folder = PropertyStore.captureFolder(id)
    do {
      let archive = try await Task.detached(priority: .userInitiated) {
        try SpotTake.package(folder: folder)
      }.value
      await upload(archive)
    } catch {
      working = ""
      problem = error.localizedDescription
    }
  }

  private func upload(_ archive: URL) async {
    spots = PropertyScan.spots(for: id)
    guard let client = StudioClient.configured else {
      working = ""
      problem = StudioFailure.notConfigured.localizedDescription
      return
    }
    problem = ""
    working = "Uploading the scan…"
    do {
      remote = try await client.upload(archive: archive, id: id, name: property?.name ?? "")
      store.update(id) { $0.uploaded = true }
      moved = false
    } catch {
      problem = error.localizedDescription
    }
    working = ""
  }

  private func delete() async {
    if property?.uploaded == true, let client = StudioClient.configured {
      do { try await client.delete(id) } catch {
        problem = "The tour could not be deleted from Tour Studio, so nothing was removed. "
          + error.localizedDescription
        return
      }
    }
    store.remove(id)
    dismiss()
  }
}

private struct GuideStep: View {
  let symbol: String
  let text: String
  var body: some View {
    Label {
      Text(text)
    } icon: {
      Image(systemName: symbol).foregroundStyle(Color.cuseOrange)
    }
  }
}

// MARK: - Viewing a tour

/// The stitched tour, shown by Tour Studio's viewer page.
struct StudioTourScreen: View {
  @Environment(\.dismiss) private var dismiss
  let title: String
  let url: URL
  let cookie: HTTPCookie?
  var body: some View {
    NavigationStack {
      StudioWebView(url: url, cookie: cookie).ignoresSafeArea(edges: .bottom)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Done") { dismiss() } }
    }
  }
}

struct StudioWebView: UIViewRepresentable {
  let url: URL
  let cookie: HTTPCookie?
  func makeCoordinator() -> Coordinator { Coordinator(origin: url) }
  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .zero, configuration: configuration)
    web.navigationDelegate = context.coordinator
    web.isOpaque = false
    web.backgroundColor = .systemBackground
    let target = url
    Task { @MainActor [weak web] in
      // The store is not persistent, so the token leaves with the web view.
      if let cookie { await configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
      web?.load(URLRequest(url: target))
    }
    return web
  }
  func updateUIView(_ uiView: WKWebView, context: Context) {}
  static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
    view.stopLoading()
    view.navigationDelegate = nil
  }
  /// Keeps the web view on the tour page it was opened for.
  final class Coordinator: NSObject, WKNavigationDelegate {
    let origin: URL
    init(origin: URL) { self.origin = origin }
    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      let target = navigationAction.request.url
      let same =
        target?.scheme == origin.scheme && target?.host == origin.host
        && target?.port == origin.port && target?.path == origin.path
      decisionHandler(same ? .allow : .cancel)
    }
  }
}

// MARK: - Settings

struct StudioSettingsView: View {
  @AppStorage(StudioClient.addressKey) private var address = ""
  @State private var result = ""
  @State private var checking = false
  @State private var token = ""
  @State private var hasToken = StudioToken.read() != nil

  var body: some View {
    Form {
      Section {
        TextField("https://…", text: $address).keyboardType(.URL).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        SecureField(hasToken ? "Access token (saved)" : "Access token", text: $token)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        if !token.isEmpty {
          Button("Save token") { saveToken() }
        } else if hasToken {
          Button("Remove saved token", role: .destructive) {
            StudioToken.save(nil)
            hasToken = false
          }
        }
        Button("Test connection") { Task { await test() } }.disabled(checking)
        if checking { ProgressView() }
        if !result.isEmpty { Text(result).foregroundStyle(.secondary) }
      } header: {
        Text("Tour Studio address")
      } footer: {
        Text(
          "Your private service that stitches scans into tours. Scans contain photos of the room; they and the token are sent only to this address. The token is kept in this iPhone's Keychain."
        )
      }
      #if DEBUG
        Section("Developer") {
          NavigationLink("Device capture check") { DeviceCaptureCheckView() }
        }
      #endif
    }
    .navigationTitle("Settings")
  }

  private func test() async {
    guard let url = StudioClient.address(address) else {
      result = "Enter an https address with no path, for example https://studio.example.net:10445"
      return
    }
    checking = true
    let outcome = await StudioClient(base: url, token: StudioToken.read()).check()
    checking = false
    result = outcome
  }

  private func saveToken() {
    guard StudioToken.isValid(token) else {
      result = "A token is at least \(StudioToken.minimumLength) letters and digits."
      return
    }
    hasToken = StudioToken.save(token)
    result = hasToken ? "Token saved." : "The token could not be saved."
    token = ""
  }
}
