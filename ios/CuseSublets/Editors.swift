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
struct ListingManageView: View {
  @EnvironmentObject var state: AppState
  let listing: Listing
  @State private var current: Listing?
  @State private var picking = false
  @State private var kind = "media"
  @State private var editing = false
  @State private var busy = false
  @State private var error = ""
  @State private var notice = ""
  var l: Listing { current ?? listing }
  var body: some View {
    List {
      Section {
        Text(l.title).font(.title2.bold())
        StatusText(text: l.status)
        NavigationLink("View listing") { ListingView(listing: l) }
        Button("Edit details") { editing = true }
        if l.status == "approved" {
          Button("Pause listing") { change("pause") }
        } else if l.status == "paused" || l.status == "pending" {
          Button("Publish listing") { change("publish") }
        }
      }
      Section("Photos, video & room scans") {
        Button("Upload photo or video") {
          kind = "media"
          picking = true
        }
        NavigationLink("Capture or manage photographic tours") { RoomToursView(listing: l) }
        NavigationLink("Capture or manage room layouts") { RoomScansView(listing: l) }
      }
      Section("Independent checks") {
        ChecksView(identity: l.hostIdentity, lease: l.leaseStatus, permission: l.permissionStatus)
        Button("Upload private lease evidence") {
          kind = "lease"
          picking = true
        }
        Button("Upload private sublet permission") {
          kind = "permission"
          picking = true
        }
        Text("Evidence is visible to you and staff. Replacement evidence resets that check.").font(
          .caption)
      }
      if busy { ProgressView() }
      if !notice.isEmpty { Text(notice) }
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    }.navigationTitle("Manage place").task { await load() }.sheet(isPresented: $editing) {
      NavigationStack { ListingEditor(existing: l, onSaved: { Task { await load() } }) }
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
struct SearchEditor: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) var dismiss
  let search: HousingSearch?
  let onSaved: () -> Void
  @State private var start = Date()
  @State private var end = Date().addingTimeInterval(86400 * 90)
  @State private var minimum = ""
  @State private var maximum = "1000"
  @State private var bedrooms = ""
  @State private var roomType = "Any"
  @State private var required = ""
  @State private var preferred = ""
  @State private var intro = ""
  @State private var active = false
  @State private var areas: [SearchArea] = []
  @State private var drawing: [GeoPoint] = []
  @State private var areaName = ""
  @State private var revision = 0
  @State private var loaded = false
  @State private var busy = false
  @State private var error = ""
  var data: [String: Any] {
    [
      "startDate": isoDay(start), "endDate": isoDay(end), "minBudget": minimum,
      "maxBudget": maximum, "minBedrooms": bedrooms, "roomType": roomType,
      "requiredAmenities": conditions(required), "preferredAmenities": conditions(preferred),
      "areas": areas.map { try! $0.dictionary() }, "introduction": intro, "activate": active,
    ]
  }
  func conditions(_ s: String) -> [String] {
    s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
  }
  var body: some View {
    Form {
      Section("Your plans") {
        DatePicker("From", selection: $start, displayedComponents: .date)
        DatePicker("Until", selection: $end, displayedComponents: .date)
        TextField("Minimum monthly rent (optional)", text: $minimum).keyboardType(.numberPad)
        TextField("Maximum monthly rent", text: $maximum).keyboardType(.numberPad)
        Picker("Room type", selection: $roomType) {
          ForEach(["Any", "Private room", "Entire place"], id: \.self) { Text($0) }
        }
        if roomType == "Entire place" {
          TextField("Minimum bedrooms (optional)", text: $bedrooms).keyboardType(.numberPad)
        }
      }
      Section("Desired areas") {
        ForEach(areas) { a in
          HStack {
            Text(a.label)
            Spacer()
            Button("Remove", role: .destructive) { areas.removeAll { $0.id == a.id } }
          }
        }
        MapReader { proxy in
          Map(
            initialPosition: .region(
              MKCoordinateRegion(
                center: .init(latitude: 43.04, longitude: -76.13),
                span: .init(latitudeDelta: 0.1, longitudeDelta: 0.1)))
          ) {
            ForEach(areas) { area in
              MapPolygon(
                coordinates: area.points.map { .init(latitude: $0.lat, longitude: $0.lng) }
              ).foregroundStyle(Color.cuseOrange.opacity(0.2))
            }
            if drawing.count > 1 {
              MapPolyline(coordinates: drawing.map { .init(latitude: $0.lat, longitude: $0.lng) })
                .stroke(.orange, lineWidth: 3)
            }
          }.onTapGesture { point in
            if drawing.count < 25, let c = proxy.convert(point, from: .local) {
              drawing.append(.init(lat: c.latitude, lng: c.longitude))
            }
          }
        }.frame(height: 260)
        Text(
          "Tap at least three corners around an area in Syracuse, name it, then add it. Up to five areas."
        ).font(.caption)
        TextField("Area name", text: $areaName)
        HStack {
          Button("Undo point") { if !drawing.isEmpty { drawing.removeLast() } }
          Button("Add area") {
            areas.append(.init(id: UUID().uuidString, label: areaName, points: drawing))
            drawing = []
            areaName = ""
          }.disabled(drawing.count < 3 || areaName.isEmpty || areas.count >= 5)
        }
      }
      Section("Conditions and introduction") {
        TextField("Required conditions, comma separated", text: $required)
        TextField("Preferred conditions, comma separated", text: $preferred)
        TextField("Introduce yourself", text: $intro, axis: .vertical)
        Toggle("Make my search visible", isOn: $active)
      }
      Button("Save private draft & finish later") {
        Task { await save(close: true, publish: false) }
      }.disabled(busy || !loaded)
      Button("Save housing search") { Task { await save(close: true, publish: true) } }.disabled(
        busy || !loaded)
      if busy { ProgressView() }
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    }.navigationTitle("Housing search").toolbar { Button("Close") { dismiss() }.disabled(busy) }
      .interactiveDismissDisabled(busy).task { await load() }
  }
  func load() async {
    guard !loaded else { return }
    do {
      if let s = search {
        start = parseDay(s.startDate)
        end = parseDay(s.endDate)
        minimum = s.minBudget.map { String($0) } ?? ""
        maximum = String(s.maxBudget)
        bedrooms = s.minBedrooms.map { String($0) } ?? ""
        roomType = s.roomType
        required = s.requiredAmenities.joined(separator: ", ")
        preferred = s.preferredAmenities.joined(separator: ", ")
        intro = s.introduction
        active = s.status == "active"
        areas = s.areas
      }
      let r: DraftResponse = try await state.api.get("/api/drafts/search")
      revision = r.revision
      if let d = r.draft {
        let v = d.data.mapValues(\.value)
        start = parseDay(v["startDate"] as? String ?? "")
        end = parseDay(v["endDate"] as? String ?? "")
        minimum = v["minBudget"] as? String ?? ""
        maximum = v["maxBudget"] as? String ?? ""
        bedrooms = v["minBedrooms"] as? String ?? ""
        roomType = v["roomType"] as? String ?? "Any"
        required = (v["requiredAmenities"] as? [String] ?? []).joined(separator: ", ")
        preferred = (v["preferredAmenities"] as? [String] ?? []).joined(separator: ", ")
        intro = v["introduction"] as? String ?? ""
        active = v["activate"] as? Bool ?? false
        if let a = v["areas"] {
          areas = try JSONDecoder().decode(
            [SearchArea].self, from: JSONSerialization.data(withJSONObject: a))
        }
      }
      loaded = true
    } catch { self.error = error.localizedDescription }
  }
  func save(close: Bool, publish: Bool) async {
    busy = true
    defer { busy = false }
    do {
      let r: DraftResponse = try await state.api.post(
        "/api/drafts/search", ["kind": "search", "step": 4, "revision": revision, "data": data])
      revision = r.revision
      if publish {
        guard let max = Double(maximum) else { throw APIError(message: "Enter a maximum rent") }
        var b = data
        b["maxBudget"] = max
        b["minBudget"] = minimum.isEmpty ? nil : Double(minimum)
        b["minBedrooms"] = bedrooms.isEmpty || roomType != "Entire place" ? nil : Double(bedrooms)
        b["status"] = active ? "active" : "paused"
        b["clientDraftRevision"] = revision
        try await state.api.act("/api/my-search", b)
        try await state.api.act("/api/drafts/search/delete", ["revision": revision])
      }
      onSaved()
      if close { dismiss() }
    } catch { self.error = error.localizedDescription }
  }
}
