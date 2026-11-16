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
      if recorder.turn != nil {
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

/// The live 0.5× camera, shown at a spot until its first shot is taken.
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

/// The camera screen of one spot. It opens on the live 0.5× camera with the first dot straight
/// ahead; once a shot is taken the screen is black space in which each shot stays where it was
/// taken.
struct SpotTurnView: View {
  @ObservedObject var recorder: SpotRecorder
  static let reticle: CGFloat = 64
  @State private var offScreenSince: Date?

  var body: some View {
    ZStack {
      TimelineView(.animation) { context in
        ZStack {
          SpotSpaceSurface(
            shots: recorder.pinned, rotation: recorder.deviceRotation,
            halfWidth: recorder.viewHalfWidth)
          if recorder.pinned.isEmpty { WideCameraSurface(recorder: recorder) }
          GeometryReader { geometry in
            let target = projectedTarget(in: geometry.size)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
              if let target {
                Path { path in
                  path.move(to: center)
                  path.addLine(to: target.point)
                }
                .stroke(.white, style: StrokeStyle(lineWidth: 3, dash: [3, 5]))
                if target.onScreen {
                  Circle().fill(Color(white: 0.96)).frame(width: 40, height: 40)
                    .position(target.point).accessibilityHidden(true)
                }
              }
              Circle().stroke(.white, lineWidth: 3).frame(width: Self.reticle, height: Self.reticle)
                .position(center)
              Circle().trim(from: 0, to: recorder.turn?.holdProgress ?? 0)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: Self.reticle + 10, height: Self.reticle + 10)
                .position(center).accessibilityHidden(true)
            }
            .onChange(of: target?.onScreen ?? true) { _, onScreen in
              offScreenSince = onScreen ? nil : context.date
            }
            .overlay(alignment: .top) { caption(now: context.date).padding(.top, 76) }
          }
        }
        .ignoresSafeArea()
      }
      VStack {
        HStack {
          Spacer()
          Button("Back to the map", systemImage: "xmark") { recorder.cancelSpot() }
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
    let first = recorder.turn?.captured.isEmpty ?? true
    return VStack(spacing: 4) {
      Text(away ? "Turn to the dot" : "Point the camera at the dot")
        .font(.title3.weight(.semibold))
      if first {
        Text("Hold still until the ring fills, then turn on the spot to the next dot.")
          .font(.footnote).multilineTextAlignment(.center)
      }
    }
    .foregroundStyle(.black).padding(.horizontal, 24).padding(.vertical, 14)
    .background(Color(white: 0.95), in: RoundedRectangle(cornerRadius: 10))
    .padding(.horizontal, 24)
    .accessibilityElement(children: .combine).accessibilityIdentifier("spot-caption")
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

// MARK: - Between spots

/// Between spots: the rooms captured so far, drawn from above, and the button that captures
/// where the person stands. ARKit tracks the walk with the 1× camera, which is kept off
/// screen: the only camera the person sees is the 0.5× one that takes the pictures.
struct SpotMapView: View {
  @ObservedObject var recorder: SpotRecorder
  let review: () -> Void
  let close: () -> Void

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      SpotCameraSurface(recorder: recorder).frame(width: 1, height: 1).opacity(0.01)
        .accessibilityHidden(true)
      VStack(spacing: 12) {
        HStack {
          Button("Close", systemImage: "chevron.left") { close() }.labelStyle(.iconOnly)
            .font(.title2)
          Spacer()
          Text(recorder.spots.count == 1 ? "1 spot" : "\(recorder.spots.count) spots")
            .font(.headline)
          Spacer()
          Button("Done") { review() }.buttonStyle(.borderedProminent).tint(.green)
            .foregroundStyle(.black).disabled(recorder.spots.isEmpty)
        }
        .padding(.horizontal).padding(.vertical, 8)
        SpotMapEditor(
          recorder: recorder, you: recorder.you,
          empty: "Stand where you want the first view, then tap Capture Here.",
          redo: { recorder.redoSpot($0) })
        VStack(spacing: 10) {
          if let hint = recorder.hint {
            Text(hint.message).font(.callout.weight(.semibold))
              .accessibilityIdentifier("capture-hint")
          }
          if !recorder.message.isEmpty {
            Text(recorder.message).font(.callout).multilineTextAlignment(.center)
              .accessibilityIdentifier("spot-message")
          }
          Button {
            recorder.openSpot()
          } label: {
            HStack(spacing: 10) {
              if recorder.opening { ProgressView().tint(.white) }
              Text(recorder.opening ? "Finding your position…" : "Capture Here")
            }
            .font(.title3.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
          }
          .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 8))
          .tint(.cuseButtonFill).controlSize(.large)
          .accessibilityIdentifier("next-spot")
          .disabled(
            !recorder.running || recorder.phase != .map || recorder.spotsRemaining == 0
              || recorder.opening)
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
      }
      .foregroundStyle(.white)
    }
  }
}

/// The map with what can be done to a spot on it: tap one to preview it, capture it again or
/// delete it, and drag it to where it really was.
struct SpotMapEditor: View {
  @ObservedObject var recorder: SpotRecorder
  var you: SIMD2<Float>? = nil
  /// Pinch to zoom and drag to move the map. Off inside a scrolling list, which needs the drag.
  var movable = true
  /// Shown under the map while it has no spots.
  var empty = ""
  /// Captures a spot again. Nil where capture is over.
  var redo: ((Int) -> Void)? = nil
  @State private var selected: Int?
  @State private var preview: SpotRecord?
  @State private var deleting: SpotRecord?

  private var picked: SpotRecord? { recorder.spots.first { $0.spot == selected } }

  private var help: String {
    if recorder.spots.isEmpty { return empty }
    return movable
      ? "Pinch to zoom and drag to move the map. Tap a spot to preview, recapture or delete it. Drag a spot that is in the wrong place."
      : "Tap a spot to preview or delete it. Drag a spot that is in the wrong place."
  }

  var body: some View {
    VStack(spacing: 10) {
      SpotMapCanvas(
        cells: recorder.mapCells, spots: recorder.spots, you: you, patches: recorder.patches,
        drawing: recorder.sketching, selected: $selected,
        onMove: { recorder.moveSpot($0, to: $1) }, movable: movable
      )
      .accessibilityIdentifier("captured-so-far")
      if let picked {
        HStack {
          Button("Preview 360") { preview = picked }
          if let redo, recorder.running {
            Button("Capture again") {
              selected = nil
              redo(picked.spot)
            }
          }
          Button("Delete", role: .destructive) { deleting = picked }
        }
        .buttonStyle(.bordered)
      } else if !help.isEmpty {
        Text(help).font(.caption).multilineTextAlignment(.center).opacity(0.75)
          .padding(.horizontal)
      }
    }
    .sheet(item: $preview) { spot in
      NavigationStack {
        VStack(spacing: 0) {
          SpotPreview(
            folder: recorder.folder, spot: spot,
            frames: (try? PhotoRecorder.savedFrames(in: recorder.folder)) ?? [])
          Text("Rough preview — the tour is stitched after upload.").font(.caption).padding()
        }
        .navigationTitle("Preview").navigationBarTitleDisplayMode(.inline)
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
        selected = nil
      }
      Button("Cancel", role: .cancel) { deleting = nil }
    } message: {
      Text("Its views still help the 3D model but it won't appear as a spot in the tour.")
    }
  }
}

/// How far the person has zoomed and moved the map from the view that fits everything.
struct SpotMapPose: Equatable {
  static let zoomRange: ClosedRange<CGFloat> = 0.5...8
  var zoom: CGFloat = 1
  /// Screen points the middle of the fitted map has been moved by.
  var pan: CGSize = .zero

  /// Zoomed by `factor` about a point of a map this size, so the place under the fingers
  /// stays under them.
  func zoomed(by factor: CGFloat, about anchor: CGPoint, in size: CGSize) -> SpotMapPose {
    let next = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    let fromMiddle = CGSize(
      width: anchor.x - size.width / 2 - pan.width, height: anchor.y - size.height / 2 - pan.height)
    let moved = CGSize(
      width: anchor.x - size.width / 2 - fromMiddle.width * next / zoom,
      height: anchor.y - size.height / 2 - fromMiddle.height * next / zoom)
    return SpotMapPose(zoom: next, pan: moved).moved(by: .zero, in: size)
  }

  /// Dragged by `translation`. The fitted map always still covers the middle of the screen, so
  /// it cannot be lost.
  func moved(by translation: CGSize, in size: CGSize) -> SpotMapPose {
    SpotMapPose(
      zoom: zoom,
      pan: CGSize(
        width: min(max(pan.width + translation.width, -size.width / 2 * zoom), size.width / 2 * zoom),
        height: min(max(pan.height + translation.height, -size.height / 2 * zoom), size.height / 2 * zoom)))
  }
}

/// How map metres become screen points: everything given fits, north-up in world x and z,
/// then zoomed and moved as the person left it.
struct SpotMapLayout: Equatable {
  let middle: SIMD2<Float>
  /// Screen points to a metre.
  let metre: CGFloat
  let size: CGSize
  let pose: SpotMapPose

  init(points: [SIMD2<Float>], size: CGSize, pose: SpotMapPose = SpotMapPose()) {
    var low = points.first ?? .zero
    var high = low
    for p in points {
      low = simd_min(low, p)
      high = simd_max(high, p)
    }
    let span = max(high.x - low.x, high.y - low.y, 2)
    metre = min(size.width, size.height) / CGFloat(span + 0.6) * pose.zoom
    middle = (low + high) / 2
    self.size = size
    self.pose = pose
  }

  func screen(_ p: SIMD2<Float>) -> CGPoint {
    CGPoint(
      x: size.width / 2 + pose.pan.width + CGFloat(p.x - middle.x) * metre,
      y: size.height / 2 + pose.pan.height + CGFloat(p.y - middle.y) * metre)
  }

  func world(_ point: CGPoint) -> SIMD2<Float> {
    guard metre > 0 else { return middle }
    return SIMD2(
      middle.x + Float((point.x - size.width / 2 - pose.pan.width) / metre),
      middle.y + Float((point.y - size.height / 2 - pose.pan.height) / metre))
  }
}

/// The captured room from above: each spot's sketch of the room around it, the walked floor in
/// its colours, the spots, and where the phone is now. It opens with everything fitted in.
/// With `movable` it can be pinched and dragged, and a double tap fits everything again. With
/// `selected`, a tap picks a spot; with `onMove`, a spot can be dragged to where it really was.
struct SpotMapCanvas: View {
  let cells: [TopDownCell]
  let spots: [SpotRecord]
  let you: SIMD2<Float>?
  var patches: [Int: UIImage] = [:]
  /// Spots whose sketch is still being drawn.
  var drawing: Set<Int> = []
  var selected: Binding<Int?>? = nil
  var onMove: ((Int, SIMD2<Float>) -> Void)? = nil
  var movable = false
  /// Metres of floor picture around a spot that the map makes room for.
  static let patchMargin: Float = 2.5
  static let marker: CGFloat = 15

  private struct Drag: Equatable {
    var spot: Int
    var place: SIMD2<Float>
    /// Frozen while dragging, so the map does not rescale under the finger.
    var layout: SpotMapLayout
  }
  @State private var drag: Drag?
  @State private var pose = SpotMapPose()
  /// The pose when the pinch or drag under way began.
  @State private var poseBefore: SpotMapPose?
  @State private var pinching = false

  private func place(of spot: SpotRecord) -> SIMD2<Float> {
    if let drag, drag.spot == spot.spot { return drag.place }
    return SIMD2(Float(spot.position[0]), Float(spot.position[2]))
  }

  private func layout(in size: CGSize) -> SpotMapLayout {
    if let drag, drag.layout.size == size { return drag.layout }
    let size2 = CoverageMap.voxelSize
    var points = cells.map { (SIMD2<Float>(Float($0.x), Float($0.z)) + 0.5) * size2 }
    for spot in spots {
      let p = SIMD2(Float(spot.position[0]), Float(spot.position[2]))
      points.append(p)
      if patches[spot.spot] != nil {
        points.append(p - Self.patchMargin)
        points.append(p + Self.patchMargin)
      }
    }
    if let you { points.append(you) }
    return SpotMapLayout(points: points, size: size, pose: pose)
  }

  /// One finger moves the map; two zoom it about the place between them.
  private func reshape(in size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 4).simultaneously(with: MagnifyGesture())
      .onChanged { value in
        if let pinch = value.second {
          // A pinch takes over from where a drag had got to, and the drag is then ignored:
          // it follows one of the two fingers.
          if !pinching {
            pinching = true
            poseBefore = pose
          }
          pose = (poseBefore ?? pose).zoomed(
            by: pinch.magnification, about: pinch.startLocation, in: size)
        } else if let pan = value.first {
          let from = poseBefore ?? pose
          poseBefore = from
          pose = from.moved(by: pan.translation, in: size)
        }
      }
      .onEnded { _ in
        poseBefore = nil
        pinching = false
      }
  }

  var body: some View {
    GeometryReader { geometry in
      let layout = layout(in: geometry.size)
      let picked = selected?.wrappedValue
      ZStack {
        Canvas { context, _ in
          guard !spots.isEmpty || !cells.isEmpty || you != nil else { return }
          // Floor pictures first, the spot being dragged last so it stays on top.
          let order = spots.sorted { a, b in
            (drag?.spot == a.spot ? 1 : 0, a.spot) < (drag?.spot == b.spot ? 1 : 0, b.spot)
          }
          for spot in order {
            guard let picture = patches[spot.spot] else { continue }
            let centre = layout.screen(place(of: spot))
            let half = CGFloat(FloorPatch.radius) * layout.metre
            context.draw(
              Image(uiImage: picture),
              in: CGRect(x: centre.x - half, y: centre.y - half, width: half * 2, height: half * 2))
          }
          let size2 = CoverageMap.voxelSize
          let side = CGFloat(size2) * layout.metre + 0.5
          for cell in cells {
            let c = (SIMD2<Float>(Float(cell.x), Float(cell.z)) + 0.5) * size2
            let shade: Float = cell.obstacle ? 0.55 : 1
            let color = Color(
              red: Double(cell.color.x * shade), green: Double(cell.color.y * shade),
              blue: Double(cell.color.z * shade))
            let p = layout.screen(c)
            context.fill(
              Path(CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)),
              with: .color(color.opacity(patches.isEmpty ? 1 : 0.5)))
          }
          for spot in spots {
            let p = layout.screen(place(of: spot))
            let chosen = picked == spot.spot || drag?.spot == spot.spot
            let shape = hexagon(at: p, radius: chosen ? Self.marker + 3 : Self.marker)
            context.fill(
              shape,
              with: .color(
                chosen ? Color(red: 0.05, green: 0.1, blue: 0.85) : Color(red: 0.3, green: 0.42, blue: 1)))
            context.stroke(shape, with: .color(.white), lineWidth: chosen ? 3 : 1.5)
          }
          if let you {
            let p = layout.screen(you)
            let dot = Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
            context.fill(dot, with: .color(.green))
            context.stroke(dot, with: .color(.white), lineWidth: 2)
          }
        }
        ForEach(spots.filter { drawing.contains($0.spot) }, id: \.spot) { spot in
          // The room around this spot is still being drawn.
          ProgressView().tint(.white).position(layout.screen(place(of: spot)))
            .accessibilityLabel("Drawing the room")
        }
        if selected != nil || onMove != nil {
          ForEach(Array(spots.enumerated()), id: \.element.spot) { index, spot in
            // An invisible handle over the marker, large enough for a finger.
            Color.clear.contentShape(Circle()).frame(width: 48, height: 48)
              .position(layout.screen(place(of: spot)))
              .onTapGesture {
                selected?.wrappedValue = picked == spot.spot ? nil : spot.spot
              }
              .highPriorityGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named("spot-map"))
                  .onChanged { value in
                    let frozen = drag?.layout ?? layout
                    drag = Drag(spot: spot.spot, place: frozen.world(value.location), layout: frozen)
                  }
                  .onEnded { value in
                    let frozen = drag?.layout ?? layout
                    drag = nil
                    onMove?(spot.spot, frozen.world(value.location))
                  },
                including: onMove == nil ? .subviews : .all
              )
              .accessibilityElement()
              .accessibilityLabel("Spot \(index + 1) of \(spots.count)")
              .accessibilityAddTraits(picked == spot.spot ? [.isButton, .isSelected] : .isButton)
              .accessibilityHint(onMove == nil ? "" : "Drag to move this spot on the map")
          }
        }
      }
      .coordinateSpace(name: "spot-map")
      .contentShape(Rectangle())
      .onTapGesture(count: 2) { withAnimation { pose = SpotMapPose() } }
      .gesture(reshape(in: geometry.size), including: movable ? .all : .subviews)
    }
    .clipped()
    .accessibilityElement(children: selected == nil && onMove == nil ? .ignore : .contain)
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

  var body: some View {
    NavigationStack {
      List {
        Section {
          SpotMapEditor(
            recorder: recorder, movable: false,
            redo: { spot in
              close()
              recorder.redoSpot(spot)
            }
          )
          .frame(height: 360).listRowBackground(Color.black).foregroundStyle(.white)
          Text(recorder.spots.count == 1 ? "1 spot." : "\(recorder.spots.count) spots.")
            .font(.subheadline)
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
    }
  }
}

extension SpotRecord: Identifiable {
  var id: Int { spot }
}
