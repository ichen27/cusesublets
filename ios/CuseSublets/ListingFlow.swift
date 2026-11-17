import ARKit
import ImageIO
import MapKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Where the listing steps begin: a new place, a private draft, or a place that already exists
/// on the server and has not been published.
struct ListingFlowStart: Identifiable {
  /// The private draft's id. It also makes a repeated "create" return the same place.
  let id: String
  var place: Listing?
  static func new() -> ListingFlowStart { .init(id: UUID().uuidString) }
}

/// Listing a place in five steps: where, details, photos, scan, checks. The place is created on
/// the server, unpublished, after the details, so that photos, a scan and a lease can attach to
/// it. It goes live only when its owner publishes it on the last step.
struct ListingFlow: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) private var dismiss
  let draftID: String
  let onSaved: () -> Void

  @State private var form = ListingForm()
  @State private var step: ListingStep
  @State private var place: Listing?
  @State private var revision = 0
  @State private var loaded = false
  @State private var busy = false
  @State private var problem = ""
  @State private var notice = ""
  @State private var finished = false

  @State private var picks: [PhotosPickerItem] = []
  @State private var thumbnails: [String: UIImage] = [:]
  @State private var photoProgress = ""

  /// Whether the server builds tours; nil until it has answered.
  @State private var serverScans: Bool?
  @State private var capture: PhotoCaptureDraft?
  @State private var savedTake: PhotoCaptureDraft?
  @State private var savedSpots = 0
  @State private var tourSent = false
  @State private var discarding = false

  @State private var pickingLease = false
  @State private var leaseSent = false

  init(start: ListingFlowStart, onSaved: @escaping () -> Void) {
    draftID = start.id
    self.onSaved = onSaved
    _place = State(initialValue: start.place)
    _step = State(initialValue: start.place == nil ? .place : .photos)
  }

  private var photos: [String] { place?.images ?? [] }
  private var isLive: Bool { place?.status == "approved" }
  private var scanOffer: ScanOffer {
    ScanOffer.choose(
      serverReady: serverScans, phoneReady: ARWorldTrackingConfiguration.isSupported,
      savedSpots: savedSpots, sent: tourSent)
  }
  private var scanFolder: URL? {
    place.map { SpotTake.folder(owner: $0.ownerId, listing: $0.id) }
  }
  /// The steps before the place exists cannot be reopened here; its details are edited from
  /// the place's own page.
  private var canGoBack: Bool { step != .place && !(place != nil && step == .photos) }

  var body: some View {
    Group {
      if finished { live } else { steps }
    }
    .foregroundStyle(Color.quadInk)
    .background(Color.quadGround.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") {
          UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }.accessibilityIdentifier("dismiss-keyboard")
      }
    }
    .interactiveDismissDisabled(busy)
    .task { await load() }
    .task(id: step) {
      if step == .photos { await loadThumbnails() }
      if step == .scan { await loadScan() }
    }
    // A message about an answer stops applying once the answers change.
    .onChange(of: form) { problem = "" }
    .onChange(of: picks) { _, items in
      guard !items.isEmpty else { return }
      Task { await addPhotos(items) }
    }
    .fullScreenCover(item: $capture, onDismiss: { readSavedTake() }) { draft in
      SpotCaptureScreen(recorder: SpotRecorder(draft: draft))
    }
    .fileImporter(isPresented: $pickingLease, allowedContentTypes: [.pdf, .jpeg, .png]) { result in
      Task { await sendLease(result) }
    }
    .alert("Discard this scan?", isPresented: $discarding) {
      Button("Discard", role: .destructive) { discardScan() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes the camera images stored on this iPhone.")
    }
  }

  // MARK: Frame

  private var steps: some View {
    VStack(spacing: 0) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          switch step {
          case .place: placeStep
          case .details: detailsStep
          case .photos: photosStep
          case .scan: scanStep
          case .checks: checksStep
          }
        }
        .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollDismissesKeyboard(.interactively)
      // A new scroll view for each step, so a step opens at its top and not wherever the
      // one before it was left.
      .id(step)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) { bar }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Button {
          if canGoBack, let previous = ListingStep(rawValue: step.rawValue - 1) {
            problem = ""
            step = previous
          } else if place == nil {
            dismiss()
          } else {
            leave()
          }
        } label: {
          Image(systemName: canGoBack ? "chevron.left" : "xmark")
        }
        .buttonStyle(.quadIcon).accessibilityLabel(canGoBack ? "Back" : "Close").disabled(busy)
        Spacer()
        Button(place == nil ? "Save and finish later" : "Finish later") {
          Task { await finishLater() }
        }
        .font(.subheadline.weight(.bold)).foregroundStyle(Color.quadLink)
        .disabled(busy || !loaded)
      }
      HStack(spacing: 6) {
        ForEach(ListingStep.allCases, id: \.self) { item in
          Capsule()
            .fill(item.rawValue <= step.rawValue ? Color.quadGreen : Color.quadInk.opacity(0.1))
            .frame(height: 6)
        }
      }.accessibilityHidden(true)
      Text(step.progress).font(.caption.weight(.bold)).foregroundStyle(Color.quadMuted)
      Text(step.title).font(.title.weight(.heavy)).accessibilityAddTraits(.isHeader)
    }
    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
  }

  private var bar: some View {
    VStack(spacing: 10) {
      if !problem.isEmpty {
        Text(problem).font(.footnote.weight(.semibold)).foregroundStyle(Color(quad: 0xB42318))
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("flow-problem")
      }
      if !notice.isEmpty {
        Text(notice).font(.footnote).foregroundStyle(Color.quadMuted)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if busy {
        HStack(spacing: 8) {
          ProgressView()
          Text(busyText).font(.footnote.weight(.semibold)).foregroundStyle(Color.quadMuted)
        }
      }
      if let title = primaryTitle {
        Button(title) { Task { await primary() } }
          .buttonStyle(.quadPrimaryWide).disabled(busy || !loaded)
      }
      if let title = secondaryTitle {
        Button(title) { Task { await advance() } }
          .buttonStyle(QuadSecondaryButtonStyle(wide: true)).disabled(busy || !loaded)
      }
    }
    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
    // Solid, unlike the bars that float over a page: a message here must stay readable over
    // whatever has scrolled beneath it.
    .background {
      Color.quadGround.ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .top) {
          LinearGradient(
            colors: [Color.quadGround.opacity(0), Color.quadGround], startPoint: .top,
            endPoint: .bottom
          ).frame(height: 18).offset(y: -18).allowsHitTesting(false)
        }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("listing-flow-bar")
  }

  private var busyText: String {
    switch step {
    case .photos: return photoProgress.isEmpty ? "Working" : photoProgress
    case .scan: return "Uploading. Keep Quad open."
    default: return "Working"
    }
  }

  private var primaryTitle: String? {
    switch step {
    case .place, .details: return "Continue"
    case .photos: return photos.isEmpty ? nil : "Continue"
    case .scan:
      switch scanOffer {
      case .checking: return nil
      case .scanNow: return "Scan now"
      case .upload: return "Upload and build the tour"
      case .sent, .unavailable: return "Continue"
      }
    case .checks: return isLive ? "Finish" : "Publish my place"
    }
  }

  /// A quieter way past a step whose main button does something else.
  private var secondaryTitle: String? {
    switch step {
    case .photos: return photos.isEmpty ? "Skip for now" : nil
    case .scan:
      switch scanOffer {
      case .checking, .scanNow, .upload: return "Add it later"
      case .sent, .unavailable: return nil
      }
    default: return nil
    }
  }

  // MARK: Steps

  @ViewBuilder private var placeStep: some View {
    Text(
      "People see the neighborhood and the approximate address you type here. Leave out your unit number."
    ).foregroundStyle(Color.quadMuted)
    field("Neighborhood") { TextField("Neighborhood", text: $form.neighborhood) }
    field("Approximate address") {
      TextField("Approximate public address", text: $form.address)
    }
    VStack(alignment: .leading, spacing: 6) {
      caption("Pin")
      MapReader { proxy in
        Map(
          initialPosition: .region(
            MKCoordinateRegion(
              center: .init(latitude: form.lat, longitude: form.lng),
              span: .init(latitudeDelta: 0.04, longitudeDelta: 0.04)))
        ) {
          Marker("Your place", coordinate: .init(latitude: form.lat, longitude: form.lng))
            .tint(Color.quadOrange)
        }
        .onTapGesture { point in
          if let spot = proxy.convert(point, from: .local) {
            form.lat = spot.latitude
            form.lng = spot.longitude
          }
        }
      }
      .frame(height: 210)
      .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
      Text("Tap near your building. The pin is public, so keep it approximate.")
        .font(.caption).foregroundStyle(Color.quadMuted)
    }
    HStack {
      Text("Walk to campus").font(.body.weight(.semibold))
      Spacer()
      TextField("Minutes", value: $form.walkMinutes, format: .number)
        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 56)
        .accessibilityLabel("Walk to campus in minutes")
      Text("min").foregroundStyle(Color.quadMuted)
    }
    .modifier(FieldBox())
  }

  @ViewBuilder private var detailsStep: some View {
    field("Title") { TextField("Listing title", text: $form.title) }
    VStack(alignment: .leading, spacing: 6) {
      caption("What you are subleasing")
      HStack(spacing: 8) {
        ForEach(["Private room", "Entire place"], id: \.self) { kind in
          choice(kind, selected: form.roomType == kind) { form.roomType = kind }
        }
      }
    }
    VStack(alignment: .leading, spacing: 6) {
      caption("Rent")
      HStack {
        Text("$").font(.body.weight(.heavy))
        TextField("Monthly rent", value: $form.price, format: .number).keyboardType(.decimalPad)
        Text("per month").foregroundStyle(Color.quadMuted)
      }
      .modifier(FieldBox())
    }
    counter("Bedrooms", value: $form.beds, step: 1)
    counter("Bathrooms", value: $form.baths, step: 0.5)
    VStack(spacing: 0) {
      DatePicker("First day", selection: $form.start, displayedComponents: .date)
        .padding(.vertical, 6)
      Divider()
      DatePicker("Last day", selection: $form.end, displayedComponents: .date)
        .padding(.vertical, 6)
    }
    .font(.body.weight(.semibold))
    .modifier(FieldBox(vertical: 6))
    field("About the place") {
      TextField("Describe your place", text: $form.description, axis: .vertical)
        .lineLimit(4...10).accessibilityIdentifier("listing-description")
    }
    VStack(alignment: .leading, spacing: 8) {
      caption("What it has")
      QuadFlow(spacing: 8) {
        ForEach(form.amenityChoices, id: \.self) { amenity in
          choice(amenity, selected: form.amenities.contains(amenity)) {
            form.toggle(amenity: amenity)
          }
        }
      }
    }
  }

  @ViewBuilder private var photosStep: some View {
    Text(
      "Add up to \(ListingForm.photoLimit). The first photo is the one people see in the feed."
    ).foregroundStyle(Color.quadMuted)
    if !photos.isEmpty {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8)
      {
        ForEach(photos, id: \.self) { path in
          Color.quadPhoto.aspectRatio(1, contentMode: .fit)
            .overlay {
              if let image = thumbnails[path] {
                Image(uiImage: image).resizable().scaledToFill()
              } else {
                RemoteImage(path: path)
              }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel("Photo of your place")
        }
      }
      Text(photos.count == 1 ? "1 photo added" : "\(photos.count) photos added")
        .font(.subheadline.weight(.bold)).foregroundStyle(Color.quadGreenText)
    }
    let left = ListingForm.photosLeft(after: photos.count)
    if left > 0 {
      if photos.isEmpty {
        PhotosPicker(selection: $picks, maxSelectionCount: left, matching: .images) {
          Label("Choose photos", systemImage: "photo.on.rectangle.angled")
        }
        .buttonStyle(.quadPrimaryWide).disabled(busy)
      } else {
        PhotosPicker(selection: $picks, maxSelectionCount: left, matching: .images) {
          Label("Add more photos", systemImage: "plus")
        }
        .buttonStyle(QuadSecondaryButtonStyle(wide: true)).disabled(busy)
      }
    } else {
      Text("That is the most a place can have.").foregroundStyle(Color.quadMuted)
    }
    Text(
      "Photos are made smaller before they upload, and the location stored inside each one is left out."
    ).font(.caption).foregroundStyle(Color.quadMuted)
    if !isLive {
      Text("Your place is saved and not published yet. Nobody else can see it.")
        .font(.caption).foregroundStyle(Color.quadMuted)
    }
  }

  @ViewBuilder private var scanStep: some View {
    Text(
      "Stand in a few spots in each room and turn slowly. People can then look around in 360° from each spot."
    ).foregroundStyle(Color.quadMuted)
    VStack(alignment: .leading, spacing: 14) {
      point("lock", "A scan stays private until you look through it and add it to your listing.")
      point("eye.slash", "Put away personal papers and pictures of people first.")
      point("clock.arrow.circlepath", "You can skip this and scan later from your place's page.")
    }
    .padding(18).frame(maxWidth: .infinity, alignment: .leading).quadCard()
    switch scanOffer {
    case .checking:
      if problem.isEmpty {
        HStack(spacing: 10) {
          ProgressView()
          Text("Checking whether this place can be scanned").font(.subheadline)
            .foregroundStyle(Color.quadMuted)
        }
      } else {
        Button("Try again") { Task { await loadScan() } }.buttonStyle(.quadSecondary)
      }
    case .scanNow:
      EmptyView()
    case .upload(let spots):
      VStack(alignment: .leading, spacing: 10) {
        Label(
          spots == 1 ? "1 spot saved on this iPhone" : "\(spots) spots saved on this iPhone",
          systemImage: "checkmark.circle.fill"
        ).font(.headline).foregroundStyle(Color.quadGreenText)
        Text("Nothing has been sent yet.").font(.subheadline).foregroundStyle(Color.quadMuted)
        HStack(spacing: 10) {
          Button("Review spots") { capture = savedTake }.buttonStyle(.quadSecondary)
          Button("Discard", role: .destructive) { discarding = true }
            .font(.subheadline.weight(.bold)).padding(.horizontal, 8)
        }.disabled(busy)
      }
      .padding(18).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.quadGreenTint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    case .sent:
      VStack(alignment: .leading, spacing: 8) {
        Label("Scan uploaded", systemImage: "checkmark.circle.fill")
          .font(.headline).foregroundStyle(Color.quadGreenText)
        Text(
          "The tour is being built. When it is ready, look through it and add it to your listing from your place's page."
        ).font(.subheadline)
      }
      .padding(18).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.quadGreenTint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    case .unavailable(let reason):
      VStack(alignment: .leading, spacing: 8) {
        Text(reason).font(.headline).foregroundStyle(Color.quadOrangeTintText)
        Text("Your listing works without a scan. You can add one later.").font(.subheadline)
      }
      .padding(18).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.quadOrangeTint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("scan-unavailable")
    }
  }

  @ViewBuilder private var checksStep: some View {
    Text(
      "People see which checks a place has. Both are optional, and a member of staff reviews each one."
    ).foregroundStyle(Color.quadMuted)
    VStack(alignment: .leading, spacing: 0) {
      let idChecked = state.user?.identity == "verified"
      checkRow(done: idChecked, text: idChecked ? "Your ID is checked" : "Your ID is not checked yet")
      {
        if !idChecked {
          NavigationLink("Add ID") { ProfileEditor() }
            .font(.subheadline.weight(.bold)).foregroundStyle(Color.quadLink)
        }
      }
      Divider().padding(.leading, 46)
      let leaseChecked = place?.leaseStatus == "verified"
      checkRow(
        done: leaseChecked,
        text: leaseChecked
          ? "Lease reviewed by staff"
          : leaseSent ? "Lease sent. Staff will review it." : "Lease not checked yet"
      ) {
        if !leaseChecked {
          Button(leaseSent ? "Replace" : "Upload lease") { pickingLease = true }
            .font(.subheadline.weight(.bold)).foregroundStyle(Color.quadLink).disabled(busy)
        }
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 6).quadCard()
    Text(
      "Your lease is seen only by you and staff. Publishing does not check anything by itself."
    ).font(.caption).foregroundStyle(Color.quadMuted)
    if isLive {
      Text("Your place is already published.").font(.caption).foregroundStyle(Color.quadMuted)
    }
  }

  private var live: some View {
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "checkmark").font(.system(size: 40, weight: .heavy))
        .foregroundStyle(.white).frame(width: 92, height: 92)
        .background(Color.quadGreen, in: Circle()).accessibilityHidden(true)
      Text("Your place is live").font(.largeTitle.weight(.heavy))
      VStack(spacing: 8) {
        Text("People can find it in the feed now.")
        if photos.isEmpty { Text("It has no photos yet. Add some from your place's page.") }
        if tourSent {
          Text("Your tour is still being built. Add it from your place's page when it is ready.")
        }
        if state.user?.identity != "verified" || place?.leaseStatus != "verified" {
          Text("Publishing did not check your ID or your lease. Staff review those separately.")
        }
      }
      .multilineTextAlignment(.center).foregroundStyle(Color.quadMuted)
      Spacer()
      if let place {
        NavigationLink("Manage my place") { ListingManageView(listing: place) }
          .buttonStyle(QuadSecondaryButtonStyle(wide: true))
      }
      Button("Done") { dismiss() }.buttonStyle(.quadPrimaryWide)
    }
    .padding(24)
  }

  // MARK: Pieces

  private func caption(_ text: String) -> some View {
    Text(text).font(.caption.weight(.bold)).foregroundStyle(Color.quadMuted)
  }

  private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      caption(title)
      content().modifier(FieldBox())
    }
  }

  /// One answer among several. The chosen ones are green.
  private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if selected { Image(systemName: "checkmark").imageScale(.small) }
        Text(title)
      }
      .font(.subheadline.weight(.bold))
      .foregroundStyle(selected ? Color.quadGreenText : Color.quadInk)
      .padding(.horizontal, 14).frame(minHeight: 40)
      .background(selected ? Color.quadGreenTint : Color.white, in: Capsule())
      .overlay(
        Capsule().strokeBorder(
          selected ? Color.quadGreen.opacity(0.35) : Color.quadInk.opacity(0.08)))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }

  private func counter(_ title: String, value: Binding<Double>, step: Double) -> some View {
    HStack(spacing: 10) {
      Text(title).font(.body.weight(.semibold))
      Spacer()
      Button {
        value.wrappedValue = max(1, value.wrappedValue - step)
      } label: {
        Image(systemName: "minus")
      }
      .buttonStyle(.quadIcon).accessibilityLabel("Fewer \(title.lowercased())")
      Text(value.wrappedValue.formatted(.number.precision(.fractionLength(0...1))))
        .font(.headline).monospacedDigit().frame(minWidth: 34)
      Button {
        value.wrappedValue = min(20, value.wrappedValue + step)
      } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(.quadIcon).accessibilityLabel("More \(title.lowercased())")
    }
    .modifier(FieldBox(vertical: 8))
  }

  private func point(_ symbol: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Color.quadGreen)
        .frame(width: 24)
      Text(text).font(.subheadline)
    }
  }

  private func checkRow<Trailing: View>(
    done: Bool, text: String, @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: done ? "checkmark.circle.fill" : "circle")
        .font(.title3).foregroundStyle(done ? Color.quadGreen : Color.quadInk.opacity(0.25))
        .frame(width: 30)
      Text(text).font(.subheadline.weight(.semibold))
      Spacer(minLength: 8)
      trailing()
    }
    .padding(.vertical, 14)
  }

  // MARK: Actions

  private func load() async {
    guard !loaded else { return }
    do {
      if place != nil {
        try await reloadPlace()
      } else {
        let saved: DraftResponse = try await state.api.get("/api/drafts/\(draftID)")
        revision = saved.revision
        if let draft = saved.draft { form = ListingForm(draft: draft.data.mapValues(\.value)) }
      }
      loaded = true
    } catch { problem = error.localizedDescription }
  }

  private func reloadPlace() async throws {
    guard let id = place?.id else { return }
    let fresh: ListingResponse = try await state.api.get("/api/listings/\(id)")
    place = fresh.listing
  }

  private func primary() async {
    if step == .scan {
      switch scanOffer {
      case .scanNow:
        guard let place else { return }
        capture = PhotoCaptureDraft(
          id: UUID().uuidString, ownerId: place.ownerId, listingId: place.id, name: "Whole place")
        return
      case .upload:
        await uploadScan()
        return
      case .checking:
        return
      case .sent, .unavailable:
        break
      }
    }
    await advance()
  }

  private func advance() async {
    problem = ""
    if let message = form.problem(in: step, today: Date()) {
      problem = message
      return
    }
    switch step {
    case .place: step = .details
    case .details: await createPlace()
    case .photos: step = .scan
    case .scan: step = .checks
    case .checks: await publish()
    }
  }

  private func saveDraft() async throws {
    try ListingInputValidation.validate(
      price: form.price, beds: form.beds, baths: form.baths, walkMinutes: form.walkMinutes,
      lat: form.lat, lng: form.lng)
    let saved: DraftResponse = try await state.api.post(
      "/api/drafts/\(draftID)",
      ["revision": revision, "kind": "listing", "step": 4, "data": form.draft])
    revision = saved.revision
  }

  private func createPlace() async {
    busy = true
    defer { busy = false }
    do {
      try await saveDraft()
      var body = form.payload(publishID: draftID)
      body["clientDraftRevision"] = revision
      let created: ListingResponse = try await state.api.post("/api/listings", body)
      place = created.listing
      onSaved()
      do {
        try await state.api.act("/api/drafts/\(draftID)/delete", ["revision": revision])
      } catch {
        notice = "Your place is saved. A private draft of it remains in You; it is safe to ignore."
      }
      step = .photos
    } catch { problem = error.localizedDescription }
  }

  private func finishLater() async {
    guard place == nil else {
      leave()
      return
    }
    busy = true
    defer { busy = false }
    do {
      try await saveDraft()
      onSaved()
      dismiss()
    } catch { problem = error.localizedDescription }
  }

  private func leave() {
    onSaved()
    dismiss()
  }

  private func publish() async {
    guard let id = place?.id else { return }
    if isLive {
      finished = true
      return
    }
    busy = true
    defer { busy = false }
    do {
      let published: ListingResponse = try await state.api.post("/api/listings/\(id)/publish")
      place = published.listing
      onSaved()
      finished = published.listing.status == "approved"
      if !finished { problem = "Your place could not be published yet. Staff may need to review it." }
    } catch { problem = error.localizedDescription }
  }

  private func addPhotos(_ items: [PhotosPickerItem]) async {
    guard let id = place?.id else { return }
    busy = true
    problem = ""
    defer {
      busy = false
      picks = []
      photoProgress = ""
    }
    var failed = 0
    var reason = ""
    for (index, item) in items.enumerated() {
      photoProgress = "Adding photo \(index + 1) of \(items.count)"
      do {
        guard let raw = try await item.loadTransferable(type: Data.self),
          let jpeg = await Task.detached(
            priority: .userInitiated, operation: { ListingPhoto.prepared(raw) }
          ).value
        else { throw APIError(message: "That photo could not be read.") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString + ".jpg")
        try jpeg.write(to: file, options: .completeFileProtection)
        defer { try? FileManager.default.removeItem(at: file) }
        let before = Set(photos)
        try await state.api.upload("/api/listings/\(id)/media", file: file)
        try await reloadPlace()
        let added = photos.filter { !before.contains($0) }
        if added.count == 1 { thumbnails[added[0]] = smallImage(jpeg) }
      } catch {
        failed += 1
        reason = error.localizedDescription
      }
    }
    if failed > 0 {
      problem =
        (failed == 1 ? "1 photo was not added: " : "\(failed) photos were not added: ") + reason
    }
  }

  /// Photos of an unpublished place are served only to its signed-in owner, which the plain
  /// image loader is not, so they are fetched through the app's own session.
  private func loadThumbnails() async {
    guard !isLive else { return }
    for path in photos where thumbnails[path] == nil && path.hasPrefix("/api/media/") {
      guard let file = try? await state.api.download(path, name: "photo.jpg") else { continue }
      if let data = try? Data(contentsOf: file) { thumbnails[path] = smallImage(data) }
      try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
  }

  private func loadScan() async {
    guard let id = place?.id else { return }
    readSavedTake()
    problem = ""
    do {
      let tours: ToursResponse = try await state.api.get("/api/listings/\(id)/tours")
      serverScans = tours.captureEnabled
      if !tours.tours.isEmpty && savedSpots == 0 { tourSent = true }
    } catch { problem = error.localizedDescription }
  }

  private func readSavedTake() {
    guard let place, let folder = scanFolder else { return }
    // A take that ended before its first spot was finished would block the next one.
    try? SpotTake.discardIfEmpty(folder: folder)
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("draft.json")),
      let draft = try? JSONDecoder().decode(PhotoCaptureDraft.self, from: data),
      draft.ownerId == state.user?.id, draft.listingId == place.id
    else {
      savedTake = nil
      savedSpots = 0
      return
    }
    savedTake = draft
    savedSpots =
      SpotTake.savedSpots(
        in: folder, frames: (try? PhotoRecorder.savedFrames(in: folder)) ?? []
      ).count
  }

  private func uploadScan() async {
    guard let id = place?.id, let take = savedTake, let folder = scanFolder else { return }
    busy = true
    problem = ""
    defer { busy = false }
    do {
      try await SpotTourUpload.send(api: state.api, listingID: id, draft: take, folder: folder)
      savedTake = nil
      savedSpots = 0
      tourSent = true
    } catch { problem = error.localizedDescription }
  }

  private func discardScan() {
    guard let folder = scanFolder else { return }
    do {
      try FileManager.default.removeItem(at: folder)
      savedTake = nil
      savedSpots = 0
    } catch { problem = error.localizedDescription }
  }

  private func sendLease(_ result: Result<URL, Error>) async {
    guard let id = place?.id else { return }
    busy = true
    problem = ""
    defer { busy = false }
    do {
      try await state.api.upload(
        "/api/listings/\(id)/documents", file: result.get(), fields: ["kind": "lease"])
      leaseSent = true
      try await reloadPlace()
    } catch { problem = error.localizedDescription }
  }
}

/// The white rounded box that every typed answer sits in.
private struct FieldBox: ViewModifier {
  var vertical: CGFloat = 14
  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 16).padding(.vertical, vertical)
      .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .strokeBorder(Color.quadInk.opacity(0.08)))
  }
}

private func smallImage(_ data: Data) -> UIImage? {
  guard let source = CGImageSourceCreateWithData(data as CFData, nil),
    let image = CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 420,
      ] as CFDictionary)
  else { return nil }
  return UIImage(cgImage: image)
}
