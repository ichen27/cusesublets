import ARKit
import SceneKit
import SwiftUI

/// Full-screen spot capture: turning at a spot, the capture map between spots, and review.
struct SpotCaptureScreen: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject var recorder: SpotRecorder
  /// Called after the take is packaged for upload; the screen then closes.
  var onGenerate: ((URL) -> Void)? = nil
  @State private var reviewing = false
  @State private var packaging = false

  var body: some View {
    Group {
      if case .turning = recorder.phase {
        SpotTurnView(recorder: recorder)
      } else {
        SpotMapView(recorder: recorder, review: { reviewing = true }, close: close)
      }
    }
    .task { recorder.start() }
    .onDisappear { recorder.end() }
    .onChange(of: recorder.phase) { _, phase in
      if case .ended = phase { reviewing = true }
    }
    .sheet(isPresented: $reviewing) {
      SpotReviewView(
        recorder: recorder, packaging: packaging, generate: generate, close: { reviewing = false }
      )
      .interactiveDismissDisabled(packaging)
    }
  }

  private func close() {
    recorder.end()
    dismiss()
  }

  private func generate() {
    guard !packaging else { return }
    recorder.end()
    packaging = true
    let folder = recorder.folder
    Task {
      do {
        let archive = try await Task.detached(priority: .userInitiated) {
          try SpotTake.package(folder: folder)
        }.value
        packaging = false
        reviewing = false
        onGenerate?(archive)
        dismiss()
      } catch {
        packaging = false
        recorder.message = error.localizedDescription
      }
    }
  }
}

/// The 0.5× camera, shown while turning at a spot.
struct WideCameraSurface: UIViewRepresentable {
  let recorder: SpotRecorder
  func makeUIView(context: Context) -> WideCameraView {
    WideCameraView(layer: recorder.wide.previewLayer)
  }
  func updateUIView(_ uiView: WideCameraView, context: Context) {}
}

struct SpotCameraSurface: UIViewRepresentable {
  let recorder: SpotRecorder
  func makeUIView(context: Context) -> ARSCNView { recorder.view }
  func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: - Turning at a spot

struct SpotTurnView: View {
  @ObservedObject var recorder: SpotRecorder
  static let reticle: CGFloat = 64
  @State private var offScreenSince: Date?

  var body: some View {
    ZStack {
      WideCameraSurface(recorder: recorder).ignoresSafeArea()
      TimelineView(.animation) { context in
        GeometryReader { geometry in
          let target = projectedTarget(in: geometry.size)
          let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
          ZStack {
            if let target, target.onScreen {
              Path { path in
                path.move(to: center)
                path.addLine(to: target.point)
              }
              .stroke(.white, style: StrokeStyle(lineWidth: 3, dash: [3, 5]))
              Circle().fill(Color(white: 0.96)).frame(width: 40, height: 40)
                .position(target.point).accessibilityHidden(true)
            } else if let target {
              Path { path in
                path.move(to: center)
                path.addLine(to: target.point)
              }
              .stroke(.white, style: StrokeStyle(lineWidth: 3, dash: [3, 5]))
            }
            Circle().stroke(.white, lineWidth: 3).frame(width: Self.reticle, height: Self.reticle)
              .position(center)
            Circle().trim(from: 0, to: recorder.turn?.holdProgress ?? 0)
              .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
              .rotationEffect(.degrees(-90)).frame(width: Self.reticle + 10, height: Self.reticle + 10)
              .position(center).accessibilityHidden(true)
          }
          .onChange(of: target?.onScreen ?? true) { _, onScreen in
            offScreenSince = onScreen ? nil : context.date
          }
          .overlay(alignment: .top) { caption(now: context.date).padding(.top, 60) }
        }
      }
      VStack {
        HStack {
          Spacer()
          Button("Cancel spot", systemImage: "xmark") { recorder.cancelSpot() }
            .labelStyle(.iconOnly).font(.title2).padding().foregroundStyle(.white)
        }
        Spacer()
        if let hint = recorder.hint {
          Text(hint.message).font(.callout.weight(.semibold)).padding(.horizontal, 14)
            .padding(.vertical, 8).background(.ultraThinMaterial, in: Capsule())
            .accessibilityIdentifier("capture-hint")
        }
        ProgressView(value: recorder.turn?.progress ?? 0).tint(.green).padding(.horizontal, 24)
          .accessibilityLabel("Spot progress")
        Button("Undo", systemImage: "arrow.uturn.backward") { recorder.undoSlice() }
          .buttonStyle(.borderedProminent).tint(Color(white: 0.15))
          .disabled((recorder.turn?.captured.isEmpty ?? true)).padding(.bottom, 24)
      }
    }
  }

  private func caption(now: Date) -> some View {
    let away = offScreenSince.map { now.timeIntervalSince($0) >= 1.5 } ?? false
    let taken = recorder.turn?.captured.count ?? 0
    let total = recorder.turn?.layout.count ?? 0
    let ring = recorder.turn?.current?.ring ?? 0
    let aim =
      ring == 1 ? "Point straight up at the ceiling" : ring == 2
      ? "Point straight down at the floor" : (away ? "Turn to the dot" : "Point the camera at the dot")
    return Text("\(aim) · \(min(taken + 1, total)) of \(total)")
      .font(.title3.weight(.semibold)).foregroundStyle(.black).padding(.horizontal, 24)
      .padding(.vertical, 14).background(Color(white: 0.95), in: RoundedRectangle(cornerRadius: 10))
      .accessibilityIdentifier("spot-caption")
  }

  /// Screen position of the current dot. Off screen (or behind the camera), the point is where
  /// the direction to it meets the screen edge.
  private func projectedTarget(in size: CGSize) -> (point: CGPoint, onScreen: Bool)? {
    guard let turn = recorder.turn, let target = turn.current,
      let projected = recorder.screenPoint(of: turn.direction(of: target), in: size)
    else { return nil }
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let point = projected.point
    let ahead = projected.ahead
    let inside = point.x >= 20 && point.x <= size.width - 20 && point.y >= 20
      && point.y <= size.height - 20
    if ahead && inside { return (point, true) }
    var dx = point.x - center.x
    var dy = point.y - center.y
    if abs(dx) < 1 && abs(dy) < 1 { dx = 1 }
    let scale = min(
      abs((size.width / 2 - 16) / max(abs(dx), 0.001)),
      abs((size.height / 2 - 16) / max(abs(dy), 0.001)))
    dx *= scale
    dy *= scale
    return (CGPoint(x: center.x + dx, y: center.y + dy), false)
  }
}

// MARK: - Capture map

struct SpotMapView: View {
  @ObservedObject var recorder: SpotRecorder
  let review: () -> Void
  let close: () -> Void

  var body: some View {
    ZStack(alignment: .top) {
      Color.black.ignoresSafeArea()
      SpotCameraSurface(recorder: recorder).frame(width: 1, height: 1).opacity(0.01)
        .accessibilityHidden(true)
      SpotMapCanvas(cells: recorder.mapCells, spots: recorder.spots, you: recorder.you)
        .padding(.top, 110).padding(.bottom, 150)
      VStack(spacing: 6) {
        HStack {
          Button("Close", systemImage: "chevron.left") { close() }.labelStyle(.iconOnly)
            .font(.title2)
          Spacer()
          Button("Done") { review() }.buttonStyle(.borderedProminent).tint(.green)
            .foregroundStyle(.black).disabled(recorder.spots.isEmpty)
        }
        HStack {
          Text("\(Int((recorder.coverage * 100).rounded()))% of room captured").font(.headline)
            .accessibilityIdentifier("spot-coverage")
          Spacer()
          Text("\(recorder.spots.count) spots")
        }
        Text("Covers floor you've walked past; unseen areas don't count.").font(.caption)
          .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
      }.padding().foregroundStyle(.white)
      VStack(spacing: 12) {
        Spacer()
        if recorder.spots.isEmpty {
          Text(
            "Put away personal papers and photos. Each spot captures the whole room around you."
          ).font(.callout).multilineTextAlignment(.center).foregroundStyle(.white).padding(.horizontal)
        }
        if let hint = recorder.hint {
          Text(hint.message).font(.callout.weight(.semibold)).padding(.horizontal, 14)
            .padding(.vertical, 8).background(.ultraThinMaterial, in: Capsule())
        }
        if !recorder.message.isEmpty {
          Text(recorder.message).font(.callout).foregroundStyle(.white).multilineTextAlignment(
            .center
          ).padding(.horizontal).accessibilityIdentifier("spot-message")
        }
        Button {
          recorder.beginSpot()
        } label: {
          Circle().fill(Color(white: 0.96)).frame(width: 72, height: 72)
            .overlay(Circle().stroke(.white, lineWidth: 3).padding(-6))
        }
        .accessibilityLabel("Capture a spot here")
        .disabled(!recorder.running || recorder.phase != .map || recorder.spotsRemaining == 0)
        .padding(.bottom, 24)
      }
    }
  }
}

/// The captured room from above: floor in its colours, obstacles darker, numbered spots, and
/// where the phone is now. Fits everything captured into the available space.
struct SpotMapCanvas: View {
  let cells: [TopDownCell]
  let spots: [SpotRecord]
  let you: SIMD2<Float>?

  var body: some View {
    Canvas { context, size in
      let size2 = CoverageMap.voxelSize
      var points = cells.map { (SIMD2<Float>(Float($0.x), Float($0.z)) + 0.5) * size2 }
      points += spots.map { SIMD2(Float($0.position[0]), Float($0.position[2])) }
      if let you { points.append(you) }
      guard let first = points.first else { return }
      var low = first
      var high = first
      for p in points {
        low = simd_min(low, p)
        high = simd_max(high, p)
      }
      let span = max(high.x - low.x, high.y - low.y, 2)
      let scale = CGFloat(min(size.width, size.height)) / CGFloat(span + 0.6)
      let middle = (low + high) / 2
      func screen(_ p: SIMD2<Float>) -> CGPoint {
        CGPoint(
          x: size.width / 2 + CGFloat(p.x - middle.x) * scale,
          y: size.height / 2 + CGFloat(p.y - middle.y) * scale)
      }
      let side = CGFloat(size2) * scale + 0.5
      for cell in cells {
        let c = (SIMD2<Float>(Float(cell.x), Float(cell.z)) + 0.5) * size2
        let shade: Float = cell.obstacle ? 0.55 : 1
        let color = Color(
          red: Double(cell.color.x * shade), green: Double(cell.color.y * shade),
          blue: Double(cell.color.z * shade))
        let p = screen(c)
        context.fill(
          Path(CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)),
          with: .color(color))
      }
      for spot in spots {
        let p = screen(SIMD2(Float(spot.position[0]), Float(spot.position[2])))
        context.fill(hexagon(at: p, radius: 15), with: .color(Color(red: 0.18, green: 0.29, blue: 1)))
        context.draw(
          Text("\(spot.spot)").font(.system(size: 14, weight: .bold)).foregroundStyle(.white),
          at: p)
      }
      if let you {
        let p = screen(you)
        let dot = Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
        context.fill(dot, with: .color(.green))
        context.stroke(dot, with: .color(.white), lineWidth: 2)
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Capture map with \(spots.count) spots")
  }

  private func hexagon(at center: CGPoint, radius: CGFloat) -> Path {
    Path { path in
      for i in 0..<6 {
        let angle = CGFloat(i) * .pi / 3 - .pi / 2
        let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
      }
      path.closeSubpath()
    }
  }
}

// MARK: - Review

struct SpotReviewView: View {
  @ObservedObject var recorder: SpotRecorder
  let packaging: Bool
  let generate: () -> Void
  let close: () -> Void
  @State private var preview: SpotRecord?
  @State private var deleting: SpotRecord?

  var body: some View {
    NavigationStack {
      List {
        Section {
          SpotMapCanvas(cells: recorder.mapCells, spots: recorder.spots, you: nil)
            .frame(height: 220).listRowBackground(Color.black)
          Text("\(Int((recorder.coverage * 100).rounded()))% of room captured · \(recorder.spots.count) spots")
        }
        Section("Spots") {
          ForEach(recorder.spots, id: \.spot) { spot in
            VStack(alignment: .leading, spacing: 8) {
              Text("Spot \(spot.spot)").font(.headline)
              HStack {
                Button("Preview 360") { preview = spot }.buttonStyle(.bordered)
                if recorder.running {
                  Button("Redo spot") {
                    close()
                    recorder.redoSpot(spot.spot)
                  }.buttonStyle(.bordered)
                }
                Button("Delete spot", role: .destructive) { deleting = spot }.buttonStyle(.bordered)
              }
            }
          }
        }
        if !recorder.message.isEmpty { Text(recorder.message).foregroundStyle(.secondary) }
        Section {
          Text("Each spot's 360 shows everything in the room. Check the previews for personal details before generating.")
            .font(.caption)
          Button("Generate tour") { generate() }.buttonStyle(.borderedProminent).tint(.cuseButtonFill)
            .disabled(!recorder.canGenerate || packaging)
          if packaging { ProgressView("Preparing upload…") }
        }
      }
      .navigationTitle("Review spots").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if recorder.running {
          ToolbarItem(placement: .cancellationAction) { Button("Keep capturing") { close() } }
        }
      }
      .sheet(item: $preview) { spot in
        NavigationStack {
          VStack(spacing: 0) {
            SpotPreview(folder: recorder.folder, spot: spot, frames: frames())
            Text("Rough preview — the tour is stitched after upload.").font(.caption).padding()
          }
          .navigationTitle("Spot \(spot.spot)").navigationBarTitleDisplayMode(.inline)
          .toolbar { Button("Done") { preview = nil } }
        }
      }
      .alert(
        "Delete this spot?",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
      ) {
        Button("Delete", role: .destructive) {
          if let spot = deleting { recorder.deleteSpot(spot.spot) }
          deleting = nil
        }
        Button("Cancel", role: .cancel) { deleting = nil }
      } message: {
        Text("Its views still help the 3D model but it won't appear as a spot in the tour.")
      }
    }
  }

  private func frames() -> [CaptureFrameRecord] {
    (try? PhotoRecorder.savedFrames(in: recorder.folder)) ?? []
  }
}

extension SpotRecord: Identifiable {
  var id: Int { spot }
}
