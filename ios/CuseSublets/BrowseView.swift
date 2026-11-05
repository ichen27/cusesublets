import MapKit
import SwiftUI

struct BrowseView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.scenePhase) private var scenePhase
  @State private var listings: [Listing] = []
  @State private var searches: [HousingSearch] = []
  @State private var mine: [Listing] = []
  @State private var mySearch: HousingSearch?
  @State private var filters = DiscoveryFilters()
  @State private var kind = "All"
  @State private var order = "Latest"
  @State private var error = ""
  @State private var showMap = false
  @State private var showFilters = false
  @State private var bounds: DiscoveryBounds?
  @State private var loading = false
  @State private var limit = 12
  @State private var loadID = UUID()
  var places: [Listing] {
    listings.filter { filters.includes($0) && !state.hiddenMemberIDs.contains($0.ownerId) }
  }
  var people: [HousingSearch] {
    searches.filter { filters.includes($0) && !state.hiddenMemberIDs.contains($0.ownerId) }
  }
  var posts: [DiscoveryPost] {
    var result: [DiscoveryPost] = []
    if kind != "People" {
      result += places.filter { bounds?.contains(.init(lat: $0.lat, lng: $0.lng)) ?? true }
        .map(DiscoveryPost.listing)
    }
    if kind != "Places" {
      var owners = Set<String>()
      result += people.filter { s in
        (bounds.map { b in s.areas.contains { b.intersects($0) } } ?? true)
          && owners.insert(s.ownerId).inserted
      }.map(DiscoveryPost.search)
    }
    return result.sorted { a, b in
      if order == "For you" {
        let af = a.fits(search: mySearch, listings: mine)
        let bf = b.fits(search: mySearch, listings: mine)
        if af != bf { return af }
      }
      return a.createdAt == b.createdAt ? a.id < b.id : a.createdAt > b.createdAt
    }
  }
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Find a sublet.\nList your place.").font(.largeTitle.bold())
          Text("Homes and people around Syracuse.").foregroundStyle(.secondary)
        }.padding(.top, 8)
        Picker("Browse", selection: $kind) {
          ForEach(["All", "Places", "People"], id: \.self) { Text($0) }
        }.pickerStyle(.segmented)
        Picker("Post order", selection: $order) {
          Text("Latest").tag("Latest")
          Text("For you").tag("For you")
        }.pickerStyle(.segmented)
        HStack {
          Button("Filters", systemImage: "line.3.horizontal.decrease") { showFilters = true }
          Spacer()
          Button(showMap ? "Hide map" : "Show map", systemImage: "map") {
            showMap.toggle()
            if !showMap { bounds = nil }
          }
        }
        if order == "For you" && mySearch?.status != "active" && mine.isEmpty {
          Text("Showing latest posts. Add a place or housing search in You to personalize matches.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if !filters.validDates {
          Text("Move out must be after move in.").foregroundStyle(.red)
        }
        if showMap {
          Map(
            initialPosition: .region(
              MKCoordinateRegion(
                center: .init(latitude: 43.04, longitude: -76.13),
                span: .init(latitudeDelta: 0.08, longitudeDelta: 0.1)))
          ) {
            if kind != "People" {
              ForEach(places) { l in
                Annotation(l.title, coordinate: l.coordinate) {
                  NavigationLink {
                    ListingView(listing: l)
                  } label: {
                    Text(dollars(l.price)).font(.caption.bold()).padding(6)
                      .background(.background, in: Capsule())
                  }.accessibilityLabel("\(l.title), \(dollars(l.price)) per month")
                }
              }
            }
            if kind != "Places" {
              ForEach(people) { person in
                ForEach(person.areas) { area in
                  MapPolygon(
                    coordinates: area.points.map {
                      CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
                    }
                  ).foregroundStyle(Color.cuseOrange.opacity(0.15))
                    .stroke(Color.cuseOrange.opacity(0.5), lineWidth: 1)
                }
              }
            }
          }.onMapCameraChange(frequency: .onEnd) { context in
            if showMap { bounds = DiscoveryBounds(context.region) }
          }.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 18))
          Text("Move the map to filter places and people's desired areas.").font(.caption)
        }
        if !error.isEmpty {
          Text(error).foregroundStyle(.red)
          Button("Retry") { Task { await load() } }
        }
        if loading { ProgressView().frame(maxWidth: .infinity) }
        Text("\(posts.count) posts" + (bounds == nil ? "" : " in this map area")).font(.caption)
        ForEach(Array(posts.prefix(limit))) { post in
          switch post {
          case .listing(let listing):
            NavigationLink {
              ListingView(listing: listing)
            } label: {
              ListingCard(listing: listing)
            }.buttonStyle(.plain)
          case .search(let search):
            NavigationLink {
              SearchDetailView(search: search)
            } label: {
              SearchCard(search: search)
            }.buttonStyle(.plain)
          }
        }
        if posts.count > limit { Button("More posts") { limit += 12 } }
        if !loading && error.isEmpty && posts.isEmpty {
          EmptyState(
            title: "No posts match", text: "Adjust your filters or explore a wider map area.")
        }
      }.padding()
    }.background(Color.cuseCream.opacity(0.45))
      .navigationTitle("CuseSublets").navigationBarTitleDisplayMode(.inline)
      .searchable(text: $filters.query, prompt: "Neighborhood, home or person")
      .toolbar {
        Button {
          state.tab = 3
        } label: {
          Image(systemName: "plus.circle.fill")
        }
        .accessibilityLabel("Post a place or housing search")
      }
      .sheet(isPresented: $showFilters) {
        DiscoveryFilterView(filters: $filters, kind: kind) { bounds = nil }
      }
      .task(id: state.user?.id) {
        order = state.user == nil ? "Latest" : "For you"
        mine = []
        mySearch = nil
        await load()
      }
      .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
      .refreshable { await load() }
  }
  func load() async {
    let request = UUID()
    loadID = request
    loading = true
    defer { if loadID == request { loading = false } }
    let owner = state.user?.id
    do {
      async let l: ListingsResponse = state.api.get("/api/listings")
      async let s: SearchesResponse = state.api.get("/api/searches")
      let publicData = try await (l, s)
      try Task.checkCancellation()
      guard loadID == request && owner == state.user?.id else { return }
      listings = publicData.0.listings
      searches = publicData.1.searches
      if owner != nil {
        async let owned: ListingsResponse = state.api.get("/api/mine")
        async let ownSearch: MySearchResponse = state.api.get("/api/my-search")
        let privateData = try await (owned, ownSearch)
        guard loadID == request && owner == state.user?.id else { return }
        mine = privateData.0.listings.filter {
          $0.status == "approved" && $0.endDate > isoDay(Date())
        }
        mySearch = privateData.1.search
      }
      error = ""
    } catch is CancellationError {} catch {
      if loadID == request && owner == state.user?.id { self.error = error.localizedDescription }
    }
  }
}
struct DiscoveryFilterView: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var filters: DiscoveryFilters
  let kind: String
  let resetMap: () -> Void
  var body: some View {
    NavigationStack {
      Form {
        Picker("Monthly budget", selection: $filters.maxPrice) {
          Text("Any budget").tag(nil as Double?)
          ForEach([700.0, 900, 1200, 1600, 2200, 3000, 5000], id: \.self) {
            Text("Up to \(dollars($0))").tag(Optional($0))
          }
        }
        Picker("Room type", selection: $filters.roomType) {
          Text("Any space").tag("")
          Text("Private room").tag("Private room")
          Text("Entire place").tag("Entire place")
        }
        Section("Dates") {
          dateControl("Move in", value: $filters.startDate)
          dateControl("Move out", value: $filters.endDate)
          if !filters.validDates { Text("Move out must be after move in.").foregroundStyle(.red) }
        }
        Toggle("Furnished", isOn: $filters.furnished)
        if kind != "People" {
          Toggle("Lease & permission checked", isOn: $filters.checked)
          Toggle("Has a photographic tour", isOn: $filters.tour)
        }
        Button("Reset filters") {
          filters = DiscoveryFilters()
          resetMap()
        }
      }.navigationTitle("Filters").toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
  }
  @ViewBuilder func dateControl(_ label: String, value: Binding<String>) -> some View {
    Toggle(
      label,
      isOn: Binding(
        get: { !value.wrappedValue.isEmpty },
        set: {
          value.wrappedValue = $0 ? isoDay(Date()) : ""
        }))
    if !value.wrappedValue.isEmpty {
      DatePicker(
        label + " date",
        selection: Binding(
          get: { parseDay(value.wrappedValue) }, set: { value.wrappedValue = isoDay($0) }),
        displayedComponents: .date)
    }
  }
}
struct ListingCard: View {
  let listing: Listing
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      RemoteImage(path: listing.images.first).frame(height: 205).clipped()
      VStack(alignment: .leading, spacing: 7) {
        HStack {
          Text(dollars(listing.price) + " / month").font(.headline)
          Spacer()
          if listing.sample { StatusText(text: "Sample") }
        }
        Text(listing.title).font(.title3.bold())
        Text("\(listing.neighborhood) · \(listing.roomType)").foregroundStyle(.secondary)
        Text("\(listing.startDate) – \(listing.endDate)").font(.caption)
        Text(listing.hostName).font(.subheadline)
      }.padding([.horizontal, .bottom])
    }.background(.background, in: RoundedRectangle(cornerRadius: 20)).clipShape(
      RoundedRectangle(cornerRadius: 20))
  }
}
struct SearchCard: View {
  let search: HousingSearch
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(search.ownerName, systemImage: "person.crop.circle").font(.headline)
      Text("Looking for \(search.roomType.lowercased())").font(.title3.bold())
      Text("Up to \(dollars(search.maxBudget)) / month")
      Text(search.areas.map(\.label).joined(separator: " · ")).foregroundStyle(.secondary)
      Text(search.introduction).lineLimit(3)
      Text("\(search.startDate) – \(search.endDate)").font(.caption)
    }.frame(maxWidth: .infinity, alignment: .leading).padding().background(
      .background, in: RoundedRectangle(cornerRadius: 20))
  }
}
struct ListingView: View {
  @EnvironmentObject var state: AppState
  let listing: Listing
  @State private var report = false
  @State private var reason = ""
  var body: some View {
    if state.hiddenMemberIDs.contains(listing.ownerId) {
      EmptyState(
        title: "Member blocked", text: "This member’s posts are hidden while you are signed in.")
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          TabView { ForEach(listing.images, id: \.self) { RemoteImage(path: $0) } }.tabViewStyle(
            .page
          ).frame(height: 280).clipped()
          VStack(alignment: .leading, spacing: 18) {
            Text(listing.title).font(.largeTitle.bold())
            Text("\(dollars(listing.price)) / month · \(listing.roomType)").font(.title3)
            if listing.sample { StatusText(text: "Sample listing — not a real offer") }
            Text("\(listing.startDate) – \(listing.endDate)").foregroundStyle(.secondary)
            Text(listing.description)
            Text(listing.amenities.joined(separator: " · ")).font(.subheadline)
            ChecksView(
              identity: listing.hostIdentity, lease: listing.leaseStatus,
              permission: listing.permissionStatus)
            NavigationLink {
              MemberView(id: listing.ownerId)
            } label: {
              Label("About \(listing.hostName)", systemImage: "person.crop.circle")
            }
            Map(interactionModes: []) {
              Marker(listing.neighborhood, coordinate: listing.coordinate)
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Text("Approximate location · \(listing.address)").font(.caption).foregroundStyle(
              .secondary)
            if let tour = listing.matterportUrl, let url = URL(string: tour), url.scheme == "https"
            {
              Link("Explore photographic tour", destination: url)
            }
            if let video = listing.videoUrl, !video.isEmpty,
              let url = URL(string: video, relativeTo: state.api.baseURL)
            {
              Link("Watch listing video", destination: url)
            }
            NavigationLink {
              RoomScansView(listing: listing)
            } label: {
              Label("Room layouts & capture", systemImage: "viewfinder")
            }
            NavigationLink("Photographic tours") { RoomToursView(listing: listing) }
            SocialView(type: "listing", targetID: listing.id)
            if state.user?.id != listing.ownerId {
              Button("Contact host") { Task { await state.contact(listingID: listing.id) } }
                .buttonStyle(.borderedProminent).tint(.cuseButtonFill).controlSize(.large).frame(
                  maxWidth: .infinity)
              Button("Report listing", role: .destructive) {
                if state.requireLogin() { report = true }
              }
            } else {
              NavigationLink("Manage listing") { ListingManageView(listing: listing) }
            }
          }.padding()
        }
      }.navigationTitle("Place").navigationBarTitleDisplayMode(.inline)
        .toolbar { ShareLink(item: state.api.url("/#listing/\(listing.id)")) }
        .alert("Report listing", isPresented: $report) {
          TextField("Reason (at least 10 characters)", text: $reason)
          Button("Send report", role: .destructive) {
            Task {
              do {
                try await state.api.act("/api/listings/\(listing.id)/report", ["reason": reason])
                reason = ""
              } catch { state.error = error.localizedDescription }
            }
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("Tell the review team what needs attention.")
        }
    }
  }
}
struct ChecksView: View {
  let identity: String
  let lease: String
  let permission: String
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("CuseSublets Checks").font(.headline)
      check("Identity verified", identity)
      check("Lease reviewed", lease)
      check("Sublet permission reviewed", permission)
      Text(
        "Checks describe specific manual reviews. Room scans do not verify ownership or permission to sublet."
      ).font(.caption).foregroundStyle(.secondary)
    }.padding().background(Color.cuseCream, in: RoundedRectangle(cornerRadius: 16))
  }
  func check(_ label: String, _ status: String) -> some View {
    Label(
      status == "verified" ? label : "\(label): \(status.replacingOccurrences(of:"_",with:" "))",
      systemImage: status == "verified" ? "checkmark.circle.fill" : "circle"
    ).font(.subheadline)
  }
}
struct SearchDetailView: View {
  @EnvironmentObject var state: AppState
  let search: HousingSearch
  @State private var mine: [Listing] = []
  @State private var report = false
  @State private var reason = ""
  var body: some View {
    if state.hiddenMemberIDs.contains(search.ownerId) {
      EmptyState(
        title: "Search unavailable",
        text: "This member’s content is hidden while you are signed in.")
    } else {
      content
    }
  }
  var content: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        SearchCard(search: search)
        Text("Required: " + search.requiredAmenities.joined(separator: ", "))
        Text("Preferred: " + search.preferredAmenities.joined(separator: ", "))
        Map {
          ForEach(search.areas) { area in
            MapPolygon(
              coordinates: area.points.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
              }
            ).foregroundStyle(Color.cuseOrange.opacity(0.25))
          }
        }.frame(height: 250)
        NavigationLink("About \(search.ownerName)") { MemberView(id: search.ownerId) }
        SocialView(type: "search", targetID: search.id)
        if state.user?.id != search.ownerId {
          if state.user == nil {
            Button("Log in to contact") { state.showLogin = true }
          } else if mine.isEmpty {
            Text("To contact this person, publish a matching listing and use Matches.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(mine) { listing in
              Button("Offer: \(listing.title)") {
                Task { await state.contact(listingID: listing.id, searchID: search.id) }
              }
            }
          }
          Button("Report housing search", role: .destructive) {
            if state.requireLogin() { report = true }
          }
        }
      }.padding()
    }.navigationTitle("Housing search")
      .alert("Report housing search", isPresented: $report) {
        TextField("Reason (at least 10 characters)", text: $reason)
        Button("Send report", role: .destructive) {
          Task {
            do {
              try await state.api.act("/api/requests/\(search.id)/report", ["reason": reason])
              reason = ""
            } catch { state.error = error.localizedDescription }
          }
        }
        Button("Cancel", role: .cancel) {}
      }
      .task(id: state.user?.id) {
        if state.user != nil {
          do {
            let r: ListingsResponse = try await state.api.get("/api/mine")
            mine = r.listings.filter { housingFits($0, search) }
          } catch { state.error = error.localizedDescription }
        }
      }
  }
}
struct MemberView: View {
  @EnvironmentObject var state: AppState
  let id: String
  @State private var detail: PublicProfileResponse?
  @State private var error = ""
  @State private var bookingID = ""
  @State private var rating = 5
  @State private var review = ""
  @State private var busy = false
  @State private var notice = ""
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        MemberSafetyActions(memberID: id)
        if state.hiddenMemberIDs.contains(id) {
          Text("This member’s content is hidden while you are signed in.")
        } else if let d = detail {
          RemoteImage(path: d.profile.avatar).frame(width: 90, height: 90).clipShape(Circle())
          Text(d.profile.name).font(.largeTitle.bold())
          StatusText(
            text: d.profile.identity == "verified" ? "Identity verified" : "Identity not verified")
          Text(d.profile.bio)
          ForEach(d.profile.photos, id: \.self) {
            RemoteImage(path: $0).frame(height: 220).clipped()
          }
          ForEach(d.profile.socials.keys.sorted(), id: \.self) { key in
            if let value = d.profile.socials[key], let url = URL(string: value),
              url.scheme == "https"
            {
              Link(key.capitalized, destination: url)
            }
          }
          if let search = d.search {
            NavigationLink {
              SearchDetailView(search: search)
            } label: {
              SearchCard(search: search)
            }
            .buttonStyle(.plain)
          }
          ForEach(d.listings) { l in
            NavigationLink {
              ListingView(listing: l)
            } label: {
              ListingCard(listing: l)
            }.buttonStyle(.plain)
          }
          Text("Completed-lease reviews").font(.title2.bold())
          if d.reviews.isEmpty {
            Text("No completed-lease reviews yet.").foregroundStyle(.secondary)
          }
          ForEach(d.reviews) { r in
            VStack(alignment: .leading) {
              Text("\(r.rating)/5 · \(r.authorName)").bold()
              Text(r.body)
            }
          }
          if !d.reviewableBookings.isEmpty {
            Text("Share your experience").font(.headline)
            Picker("Completed lease", selection: $bookingID) {
              ForEach(d.reviewableBookings) {
                Text($0.listingTitle + " · " + $0.endDate).tag($0.id)
              }
            }
            Picker("Rating", selection: $rating) {
              ForEach(1...5, id: \.self) { Text("\($0) out of 5").tag($0) }
            }
            TextField("Your review (10–2000 characters)", text: $review, axis: .vertical)
              .textFieldStyle(.roundedBorder)
            Button("Publish review") {
              Task {
                busy = true
                defer { busy = false }
                do {
                  try await state.api.act(
                    "/api/users/\(id)/reviews",
                    ["bookingId": bookingID, "rating": rating, "body": review])
                  review = ""
                  notice = "Review published"
                  await load()
                } catch { self.error = error.localizedDescription }
              }
            }.disabled(
              busy || bookingID.isEmpty
                || review.trimmingCharacters(in: .whitespacesAndNewlines).count < 10
                || review.count > 2000)
          }
        } else if error.isEmpty {
          ProgressView()
        }
        if !notice.isEmpty { Text(notice) }
        if !error.isEmpty {
          Text(error).foregroundStyle(.red)
          Button("Retry") { Task { await load() } }
        }
      }.padding()
    }.navigationTitle("Member").task(id: state.user?.id) {
      detail = nil
      review = ""
      notice = ""
      await load()
    }.refreshable { await load() }
  }
  func load() async {
    do {
      let response: PublicProfileResponse = try await state.api.get("/api/users/\(id)")
      detail = response
      if !response.reviewableBookings.contains(where: { $0.id == bookingID }) {
        bookingID = response.reviewableBookings.first?.id ?? ""
      }
      error = ""
    } catch { self.error = error.localizedDescription }
  }
}
