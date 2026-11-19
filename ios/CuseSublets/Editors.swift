import MapKit
import SwiftUI
import UniformTypeIdentifiers

enum JSONValue: Codable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([JSONValue])
  case object([String: JSONValue])
  case null
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode([JSONValue].self) {
      self = .array(v)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }
  var value: Any {
    switch self {
    case .string(let v): return v
    case .number(let v): return v
    case .bool(let v): return v
    case .array(let v): return v.map(\.value)
    case .object(let v): return v.mapValues(\.value)
    case .null: return NSNull()
    }
  }
}
struct DraftRecord: Decodable, Identifiable {
  let id: String
  let kind: String
  let revision: Int
  let data: [String: JSONValue]
}
struct DraftsResponse: Decodable { let drafts: [DraftRecord] }
struct DraftResponse: Decodable {
  let draft: DraftRecord?
  let revision: Int
}
/// Edits the details of a place that already exists ("Edit details" on its page). New places are
/// made in `ListingFlow`; the parts of this view that create one are no longer reached and can
/// go when this editor is redrawn.
struct ListingEditor: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) var dismiss
  @State private var draftID: String
  var existing: Listing?
  let onSaved: () -> Void
  init(draftID: String = UUID().uuidString, existing: Listing? = nil, onSaved: @escaping () -> Void)
  {
    _draftID = State(initialValue: draftID)
    self.existing = existing
    self.onSaved = onSaved
  }
  @State private var walkMinutes = 10.0
  @State private var title = ""
  @State private var neighborhood = ""
  @State private var address = ""
  @State private var price = 800.0
  @State private var beds = 1.0
  @State private var baths = 1.0
  @State private var roomType = "Private room"
  @State private var start = Date()
  @State private var end = Date().addingTimeInterval(86400 * 90)
  @State private var description = ""
  @State private var amenities = ""
  @State private var tour = ""
  @State private var video = ""
  @State private var images = ""
  @State private var lat = 43.037
  @State private var lng = -76.127
  @State private var revision = 0
  @State private var error = ""
  @State private var notice = ""
  @State private var busy = false
  @State private var loaded = false
  @State private var created: Listing?
  var draftData: [String: Any] {
    [
      "title": title, "neighborhood": neighborhood, "address": address, "price": price,
      "beds": beds, "baths": baths, "roomType": roomType, "startDate": isoDay(start),
      "endDate": isoDay(end), "description": description,
      "amenities": amenities.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
      "matterportUrl": tour, "videoUrl": video, "images": images, "walkMinutes": walkMinutes,
      "lat": lat,
      "lng": lng,
    ]
  }
  var body: some View {
    Form {
      if let created {
        Section {
          Text("Your place is published. Checks are still independent.")
          NavigationLink("Add photos, room scans & documents") {
            ListingManageView(listing: created)
          }
          Button("Done") { dismiss() }
        }
      } else {
        Section("Your place") {
          TextField("Listing title", text: $title)
          TextField("Neighborhood", text: $neighborhood).disabled(existing != nil)
          TextField("Approximate public address", text: $address).disabled(existing != nil)
          if existing == nil {
            TextField("Estimated walk to campus (minutes)", value: $walkMinutes, format: .number)
              .keyboardType(.numberPad)
          }
          Picker("Room type", selection: $roomType) {
            Text("Private room").tag("Private room")
            Text("Entire place").tag("Entire place")
          }.disabled(existing != nil)
          TextField("Monthly rent", value: $price, format: .number).keyboardType(.decimalPad)
          Stepper("Bedrooms: \(Int(beds))", value: $beds, in: 1...20).disabled(existing != nil)
          Stepper("Bathrooms: \(Int(baths))", value: $baths, in: 1...20).disabled(existing != nil)
        }
        Section("Availability") {
          DatePicker("From", selection: $start, displayedComponents: .date)
          DatePicker("Until", selection: $end, displayedComponents: .date)
        }
        Section("Details") {
          TextField("Describe your place", text: $description, axis: .vertical).lineLimit(4...10)
            .accessibilityIdentifier("listing-description")
          TextField("Amenities, separated by commas", text: $amenities)
        }
        if existing == nil {
          Section("Approximate map location") {
            MapReader { proxy in
              Map(
                initialPosition: .region(
                  MKCoordinateRegion(
                    center: .init(latitude: lat, longitude: lng),
                    span: .init(latitudeDelta: 0.04, longitudeDelta: 0.04)))
              ) { Marker("Your place", coordinate: .init(latitude: lat, longitude: lng)) }
              .onTapGesture { point in
                if let c = proxy.convert(point, from: .local) {
                  lat = c.latitude
                  lng = c.longitude
                }
              }
            }.frame(height: 230)
            Text("Tap near the property. This pin is public; avoid exposing a precise unit.").font(
              .caption)
          }
          Section("Existing media (optional)") {
            TextField("Photo URLs, one per line", text: $images, axis: .vertical)
              .textInputAutocapitalization(.never)
            TextField("Matterport tour URL", text: $tour).textInputAutocapitalization(.never)
            TextField("Video URL", text: $video).textInputAutocapitalization(.never)
            Text(
              "After publishing you can upload photos and privately capture a room layout before sharing it."
            ).font(.caption)
          }
          Button("Save private draft & finish later") { Task { await saveAndClose() } }.disabled(
            busy || !loaded)
        }
        Button(existing == nil ? "Publish listing" : "Save changes") { Task { await publish() } }
          .disabled(busy || !loaded)
        Text("Publishing does not verify identity, the lease, or permission to sublet.").font(
          .caption
        ).foregroundStyle(.secondary)
      }
      if busy { ProgressView() }
      if !notice.isEmpty { Text(notice) }
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    }.scrollDismissesKeyboard(.interactively)
      .navigationTitle(existing == nil ? "List your place" : "Edit listing").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) }
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") {
            UIApplication.shared.sendAction(
              #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
          }.accessibilityIdentifier("dismiss-keyboard")
        }
      }.interactiveDismissDisabled(busy).task { await load() }
  }
  func load() async {
    guard !loaded else { return }
    do {
      if let l = existing {
        title = l.title
        neighborhood = l.neighborhood
        address = l.address
        price = l.price
        beds = l.beds
        baths = l.baths
        roomType = l.roomType
        start = parseDay(l.startDate)
        end = parseDay(l.endDate)
        description = l.description
        amenities = l.amenities.joined(separator: ", ")
        lat = l.lat
        lng = l.lng
      } else {
        let r: DraftResponse = try await state.api.get("/api/drafts/\(draftID)")
        revision = r.revision
        if let d = r.draft {
          let v = d.data.mapValues(\.value)
          title = v["title"] as? String ?? ""
          neighborhood = v["neighborhood"] as? String ?? ""
          address = v["address"] as? String ?? ""
          price = v["price"] as? Double ?? 800
          walkMinutes = max(1, v["walkMinutes"] as? Double ?? 10)
          beds = v["beds"] as? Double ?? 1
          baths = v["baths"] as? Double ?? 1
          roomType = v["roomType"] as? String ?? "Private room"
          start = parseDay(v["startDate"] as? String ?? "")
          end = parseDay(v["endDate"] as? String ?? "")
          description = v["description"] as? String ?? ""
          amenities = (v["amenities"] as? [String] ?? []).joined(separator: ", ")
          tour = v["matterportUrl"] as? String ?? ""
          video = v["videoUrl"] as? String ?? ""
          images = v["images"] as? String ?? ""
          lat = v["lat"] as? Double ?? 43.037
          lng = v["lng"] as? Double ?? -76.127
        }
      }
      loaded = true
    } catch { self.error = error.localizedDescription }
  }
  func saveDraft() async throws {
    try ListingInputValidation.validate(
      price: price, beds: beds, baths: baths, walkMinutes: walkMinutes, lat: lat, lng: lng)
    let r: DraftResponse = try await state.api.post(
      "/api/drafts/\(draftID)",
      ["revision": revision, "kind": "listing", "step": 4, "data": draftData])
    revision = r.revision
  }
  func saveAndClose() async {
    busy = true
    defer { busy = false }
    do {
      try await saveDraft()
      onSaved()
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
  func publish() async {
    busy = true
    error = ""
    defer { busy = false }
    do {
      var b = draftData
      if existing == nil {
        try await saveDraft()
        b["clientPublishId"] = draftID
        b["clientDraftRevision"] = revision
        b["images"] = images.split(separator: "\n").map(String.init)
      }
      let r: ListingResponse = try await state.api.post(
        existing.map { "/api/listings/" + $0.id } ?? "/api/listings", b)
      created = r.listing
      onSaved()
      if existing != nil {
        dismiss()
      } else {
        do {
          try await state.api.act("/api/drafts/\(draftID)/delete", ["revision": revision])
        } catch { notice = "Published. A private draft remains; review it in You." }
      }
    } catch { self.error = error.localizedDescription }
  }
}
/// Your own place: its status, the way to its public page, its photos, tours and room
/// layouts, and the private documents staff check.
struct ListingManageView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) private var dismiss
  let listing: Listing
  @State private var current: Listing?
  @State private var picking = false
  @State private var kind = "media"
  @State private var editing = false
  @State private var finishing: ListingFlowStart?
  @State private var busy = false
  @State private var error = ""
  @State private var notice = ""
  var l: Listing { current ?? listing }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 12) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "chevron.left")
          }
          .buttonStyle(.quadIcon).accessibilityLabel("Back")
          Text("Your place").font(.title2.weight(.heavy)).accessibilityAddTraits(.isHeader)
        }
        .padding(.top, 4)
        summary
        section("Photos and tours") {
          rows {
            Button {
              kind = "media"
              picking = true
            } label: {
              row("Upload photo or video", "photo.on.rectangle")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 54)
            NavigationLink {
              RoomToursView(listing: l)
            } label: {
              row("360° tours", "view.3d")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 54)
            NavigationLink {
              RoomScansView(listing: l)
            } label: {
              row("Room layouts", "square.split.bottomrightquarter")
            }
            .buttonStyle(.plain)
          }
        }
        section("Checks") {
          ChecksView(identity: l.hostIdentity, lease: l.leaseStatus, permission: l.permissionStatus)
          rows {
            Button {
              kind = "lease"
              picking = true
            } label: {
              row("Upload private lease evidence", "doc.text")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 54)
            Button {
              kind = "permission"
              picking = true
            } label: {
              row("Upload private sublet permission", "signature")
            }
            .buttonStyle(.plain)
          }
          Text("Only you and staff see these. Sending a new one starts that check again.")
            .font(.footnote).foregroundStyle(Color.quadMuted)
        }
        if busy { ProgressView().frame(maxWidth: .infinity) }
        if !notice.isEmpty {
          Text(notice).font(.subheadline.weight(.bold)).foregroundStyle(Color.quadGreenText)
        }
        if !error.isEmpty {
          Text(error).font(.subheadline).foregroundStyle(Color(quad: 0xB42318))
        }
      }
      .padding(.horizontal, 16).padding(.bottom, 16)
    }
    .foregroundStyle(Color.quadInk)
    .background(Color.quadGround.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .task { await load() }.sheet(isPresented: $editing) {
      NavigationStack { ListingEditor(existing: l, onSaved: { Task { await load() } }) }
    }
    .fullScreenCover(item: $finishing, onDismiss: { Task { await load() } }) { start in
      NavigationStack { ListingFlow(start: start, onSaved: { Task { await load() } }) }
    }
    .fileImporter(
      isPresented: $picking,
      allowedContentTypes: kind == "media"
        ? [.jpeg, .png, .webP, .mpeg4Movie] : [.pdf, .jpeg, .png]
    ) { result in
      Task {
        busy = true
        defer { busy = false }
        do {
          try await state.api.upload(
            "/api/listings/\(l.id)/" + (kind == "media" ? "media" : "documents"),
            file: result.get(), fields: kind == "media" ? [:] : ["kind": kind])
          notice = "Upload saved"
          await load()
        } catch { self.error = error.localizedDescription }
      }
    }
  }
  private var summary: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        RemoteImage(path: l.images.first).frame(width: 64, height: 64)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 5) {
          Text(l.title).font(.title3.weight(.heavy))
          QuadChip(
            text: AccountView.status(l.status), kind: l.status == "approved" ? .good : .note)
        }
        Spacer(minLength: 0)
      }
      NavigationLink("View listing") { ListingView(listing: l) }
        .buttonStyle(QuadSecondaryButtonStyle(wide: true, fill: .quadWell))
      Button("Edit details") { editing = true }
        .buttonStyle(QuadSecondaryButtonStyle(wide: true, fill: .quadWell))
      if l.status == "approved" {
        Button("Pause listing") { change("pause") }
          .buttonStyle(QuadSecondaryButtonStyle(wide: true, fill: .quadWell)).disabled(busy)
      } else if l.status == "paused" || l.status == "pending" {
        Button("Publish listing") { change("publish") }.buttonStyle(.quadPrimaryWide)
          .disabled(busy)
        Button("Add photos, a scan and checks in steps") {
          finishing = ListingFlowStart(id: UUID().uuidString, place: l)
        }
        .buttonStyle(QuadSecondaryButtonStyle(wide: true, fill: .quadWell))
      }
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading).quadCard(radius: 24)
  }
  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline.weight(.heavy)).accessibilityAddTraits(.isHeader)
      content()
    }
  }
  private func rows<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(spacing: 0) { content() }.quadCard(radius: 22)
  }
  private func row(_ title: String, _ symbol: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Color.quadMuted)
        .frame(width: 26).accessibilityHidden(true)
      Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.quadInk)
      Spacer(minLength: 0)
      Image(systemName: "chevron.right").font(.footnote.weight(.bold))
        .foregroundStyle(Color.quadMuted).accessibilityHidden(true)
    }
    .padding(.horizontal, 16).padding(.vertical, 14).contentShape(Rectangle())
  }
  func load() async {
    do {
      let r: ListingResponse = try await state.api.get("/api/listings/\(listing.id)")
      current = r.listing
    } catch { self.error = error.localizedDescription }
  }
  func change(_ action: String) {
    guard !busy else { return }
    Task {
      busy = true
      defer { busy = false }
      do {
        try await state.api.act("/api/listings/\(l.id)/\(action)")
        await load()
      } catch { self.error = error.localizedDescription }
    }
  }
}
// Keep these bounds aligned with shared/drafts.ts; explain invalid input rather than moving the pin.
enum ListingInputValidation {
  static func validate(
    price: Double, beds: Double, baths: Double, walkMinutes: Double,
    lat: Double, lng: Double
  ) throws {
    for (value, range, message) in [
      (price, 0.0...20000.0, "Enter monthly rent between $0 and $20,000."),
      (beds, 0.0...20.0, "Enter between 0 and 20 bedrooms."),
      (baths, 0.0...20.0, "Enter between 0 and 20 bathrooms."),
      (walkMinutes, 0.0...120.0, "Enter a walk time between 0 and 120 minutes."),
      (lat, 42.9...43.15, "Move the approximate location pin into the Syracuse area."),
      (lng, -76.3 ... -75.95, "Move the approximate location pin into the Syracuse area."),
    ] {
      guard value.isFinite && range.contains(value) else { throw APIError(message: message) }
    }
  }
}
