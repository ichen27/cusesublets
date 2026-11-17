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
  @State private var searching = false
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
    // The header sits above the scroll view rather than in a top safe-area inset, which left an
    // empty band the height of the header above the first post.
    VStack(spacing: 0) {
      header
      feed
    }
    .background(Color.quadGround)
    .toolbar(.hidden, for: .navigationBar)
    .sheet(isPresented: $showFilters) {
      DiscoveryFilterView(filters: $filters, order: $order, kind: kind) { bounds = nil }
    }
    .task(id: state.user?.id) {
      order = state.user == nil ? "Latest" : "For you"
      mine = []
      mySearch = nil
      await load()
    }
    .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
  }
  private var feed: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        if order == "For you" && mySearch?.status != "active" && mine.isEmpty {
          Text("Showing the latest posts. Add a place or say what you're looking for to see what fits you first.")
            .font(.footnote).foregroundStyle(Color.quadMuted)
        }
        if !filters.validDates {
          Text("Move out must be after move in.").foregroundStyle(.red)
        }
        if showMap { map }
        if !error.isEmpty {
          Text(error).foregroundStyle(.red)
          Button("Retry") { Task { await load() } }.buttonStyle(.quadSecondary)
        }
        if loading && posts.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.top, 24) }
        ForEach(Array(posts.prefix(limit))) { post in
          switch post {
          case .listing(let listing):
            QuadListingCard(listing: listing, fits: post.fits(search: mySearch, listings: mine))
          case .search(let search):
            QuadSearchCard(search: search, fits: post.fits(search: mySearch, listings: mine))
          }
        }
        if posts.count > limit {
          Button("More posts") { limit += 12 }.buttonStyle(QuadSecondaryButtonStyle(wide: true))
        }
        if !loading && error.isEmpty && posts.isEmpty {
          EmptyState(
            title: "No posts match", text: "Adjust your filters or explore a wider map area.")
        }
      }
      .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 16)
    }
    .refreshable { await load() }
  }
  /// The app's name, search and filters, and the row that chooses what the feed shows.
  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        QuadLogo()
        Text("Quad").font(.title2.weight(.heavy)).foregroundStyle(Color.quadInk)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Button {
          searching.toggle()
          if !searching { filters.query = "" }
        } label: {
          Image(systemName: searching ? "xmark" : "magnifyingglass")
        }
        .buttonStyle(.quadIcon).accessibilityLabel(searching ? "Close search" : "Search")
        Button {
          showFilters = true
        } label: {
          Image(systemName: "slider.horizontal.3")
        }
        .buttonStyle(.quadIcon).accessibilityLabel("Filters")
      }
      if searching {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").foregroundStyle(Color.quadMuted)
          TextField("Neighborhood, home or person", text: $filters.query)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .submitLabel(.search)
        }
        .padding(.horizontal, 14).frame(minHeight: 46)
        .background(.white, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.quadOrange, lineWidth: 2))
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          QuadFilterChip(title: order, selected: kind == "All") { kind = "All" }
          QuadFilterChip(title: "Places", selected: kind == "Places") { kind = "Places" }
          QuadFilterChip(title: "People", selected: kind == "People") { kind = "People" }
          QuadFilterChip(title: "Map", symbol: "map", selected: showMap) {
            showMap.toggle()
            if !showMap { bounds = nil }
          }
        }
        .padding(.vertical, 2)
      }.quadSidewaysScroll()
    }
    .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
    .background(Color.quadGround)
  }
  private var map: some View {
    VStack(alignment: .leading, spacing: 8) {
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
                QuadChip(text: dollars(l.price), kind: .price)
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
              ).foregroundStyle(Color.quadOrange.opacity(0.15))
                .stroke(Color.quadOrange.opacity(0.5), lineWidth: 1)
            }
          }
        }
      }.onMapCameraChange(frequency: .onEnd) { context in
        if showMap { bounds = DiscoveryBounds(context.region) }
      }.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
      Text(
        "\(posts.count) posts in this map area. Move the map to filter places and the areas people want."
      ).font(.footnote).foregroundStyle(Color.quadMuted)
    }
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
  @Binding var order: String
  let kind: String
  let resetMap: () -> Void
  var body: some View {
    NavigationStack {
      Form {
        Picker("Show first", selection: $order) {
          Text("What fits you").tag("For you")
          Text("The latest").tag("Latest")
        }
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
/// One sublease: photos and the 360° tour first, then the person, what has been checked, the
/// details and the comments. Its own bar at the bottom carries the price and the way to reply.
struct ListingView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) private var dismiss
  let listing: Listing
  @State private var report = false
  @State private var reason = ""
  /// A published tour that is ready to open, when the place has one.
  @State private var tour: RoomTour?

  private var own: Bool { state.user?.id == listing.ownerId }

  var body: some View {
    if state.hiddenMemberIDs.contains(listing.ownerId) {
      EmptyState(
        title: "Member blocked", text: "This member’s posts are hidden while you are signed in.")
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          hero
          VStack(alignment: .leading, spacing: 16) {
            heading
            host
            checks
            about
            location
            more
            comments
            if !own {
              Button("Report listing", role: .destructive) {
                Task { if await state.signedInOrAsk() { report = true } }
              }
              .font(.subheadline.weight(.bold)).frame(minHeight: 44)
            }
          }
          .padding(.horizontal, 16)
        }
        .padding(.bottom, 16)
      }
      // This screen has no tab bar under it, so it drops the room the tab reserves for one.
      .contentMargins(.bottom, 0, for: .scrollContent)
      .background(Color.quadGround)
      .safeAreaInset(edge: .bottom, spacing: 0) { priceBar }
      .toolbar(.hidden, for: .navigationBar)
      .hidesQuadTabBar()
      .task(id: listing.id) { await loadTour() }
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

  private var hero: some View {
    TabView {
      if listing.images.isEmpty {
        RemoteImage(path: nil)
      } else {
        ForEach(listing.images, id: \.self) { RemoteImage(path: $0) }
      }
    }
    .tabViewStyle(.page)
    .quadSidewaysScroll()
    .frame(height: 280)
    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    .overlay(alignment: .top) {
      HStack(spacing: 8) {
        Button {
          dismiss()
        } label: {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.quadIcon).accessibilityLabel("Back")
        Spacer()
        ShareLink(item: state.api.url("/#listing/\(listing.id)")) {
          Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.quadIcon).accessibilityLabel("Share")
      }
      .padding(12)
    }
    .overlay(alignment: .bottomLeading) {
      if let tour {
        NavigationLink {
          TourWebView(api: state.api, listingID: listing.id, tourID: tour.id)
            .navigationTitle(tour.name).navigationBarTitleDisplayMode(.inline)
        } label: {
          Label("Look around in 360°", systemImage: "view.3d")
        }
        .buttonStyle(.quadDark).padding(12)
      }
    }
    .padding(.horizontal, 12).padding(.top, 4)
  }

  private var heading: some View {
    VStack(alignment: .leading, spacing: 6) {
      if listing.sample { QuadChip(text: "Sample listing, not a real offer", kind: .note) }
      Text(listing.title).font(.title2.weight(.heavy)).foregroundStyle(Color.quadInk)
        .accessibilityAddTraits(.isHeader)
      Text(
        QuadFormat.stay(
          roomType: listing.roomType, beds: listing.beds, baths: listing.baths,
          start: listing.startDate, end: listing.endDate)
      ).font(.subheadline).foregroundStyle(Color.quadMuted)
    }
  }

  private var host: some View {
    NavigationLink {
      MemberView(id: listing.ownerId)
    } label: {
      HStack(spacing: 12) {
        QuadAvatar(name: listing.hostName, id: listing.ownerId, size: 46)
        VStack(alignment: .leading, spacing: 2) {
          Text("Subleased by \(listing.hostName)").font(.subheadline.weight(.heavy))
          Text(listing.hostIdentity == "verified" ? "ID checked" : "ID not checked yet")
            .font(.footnote).foregroundStyle(Color.quadMuted)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.footnote.weight(.bold))
          .foregroundStyle(Color.quadMuted)
      }
      .foregroundStyle(Color.quadInk)
      .padding(12)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .quadCard()
  }

  private var checks: some View {
    let rows = QuadFormat.checks(
      hostName: listing.hostName, identity: listing.hostIdentity, lease: listing.leaseStatus)
    let any = rows.contains(where: \.done)
    return VStack(alignment: .leading, spacing: 9) {
      Label("What has been checked", systemImage: "checkmark.shield")
        .font(.headline.weight(.heavy))
        .foregroundStyle(any ? Color.quadGreenText : Color.quadInk)
      ForEach(rows, id: \.text) { row in
        Label(row.text, systemImage: row.done ? "checkmark" : "minus")
          .font(.subheadline.weight(row.done ? .semibold : .regular))
          .foregroundStyle(row.done ? Color.quadInk : Color.quadMuted)
      }
      Text("Checks lower the risk of scams. They are not a guarantee.")
        .font(.caption).foregroundStyle(any ? Color.quadGreenText : Color.quadMuted)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(
      any ? Color.quadGreenTint : Color.quadWell,
      in: RoundedRectangle(cornerRadius: 24, style: .continuous))
  }

  private var about: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("About this place").font(.headline.weight(.heavy))
      Text(listing.description).font(.subheadline)
      if !listing.amenities.isEmpty {
        QuadFlow {
          ForEach(listing.amenities, id: \.self) { amenity in
            Text(amenity).font(.footnote.weight(.semibold))
              .padding(.horizontal, 12).padding(.vertical, 7)
              .background(.white, in: Capsule())
              .overlay(Capsule().strokeBorder(Color.quadInk.opacity(0.08)))
          }
        }
        .padding(.top, 2)
      }
    }
    .foregroundStyle(Color.quadInk)
  }

  private var location: some View {
    VStack(alignment: .leading, spacing: 6) {
      Map(interactionModes: []) {
        Marker(listing.neighborhood, coordinate: listing.coordinate)
      }
      .frame(height: 180)
      .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
      Text("Approximate location · \(listing.address)").font(.caption)
        .foregroundStyle(Color.quadMuted)
    }
  }

  /// Other ways to see the place, and where its owner manages tours and layouts.
  private var more: some View {
    VStack(spacing: 0) {
      if let link = listing.matterportUrl, let url = URL(string: link), url.scheme == "https" {
        Link(destination: url) { moreRow("Open the Matterport tour", symbol: "arrow.up.right") }
        Divider().padding(.leading, 16)
      }
      if let video = listing.videoUrl, !video.isEmpty,
        let url = URL(string: video, relativeTo: state.api.baseURL)
      {
        Link(destination: url) { moreRow("Watch the video", symbol: "play.rectangle") }
        Divider().padding(.leading, 16)
      }
      NavigationLink {
        RoomToursView(listing: listing)
      } label: {
        moreRow(own ? "Scan or manage 360° tours" : "All 360° tours", symbol: "chevron.right")
      }
      Divider().padding(.leading, 16)
      NavigationLink {
        RoomScansView(listing: listing)
      } label: {
        moreRow(own ? "Capture or manage room layouts" : "Room layouts", symbol: "chevron.right")
      }
    }
    .buttonStyle(.plain)
    .quadCard()
  }

  private func moreRow(_ title: String, symbol: String) -> some View {
    HStack {
      Text(title).font(.subheadline.weight(.bold))
      Spacer()
      Image(systemName: symbol).font(.footnote.weight(.bold)).foregroundStyle(Color.quadMuted)
    }
    .foregroundStyle(Color.quadInk)
    .padding(.horizontal, 16).frame(minHeight: 52)
    .contentShape(Rectangle())
  }

  private var comments: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Questions and comments").font(.headline.weight(.heavy))
        .foregroundStyle(Color.quadInk)
      SocialView(type: "listing", targetID: listing.id)
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).quadCard()
    }
  }

  private var priceBar: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 1) {
        (Text(dollars(listing.price)).font(.title3.weight(.heavy))
          + Text(" / month").font(.footnote.weight(.bold)).foregroundColor(.quadMuted))
        Text(QuadFormat.dateRange(listing.startDate, listing.endDate)).font(.caption)
          .foregroundStyle(Color.quadMuted)
      }
      .foregroundStyle(Color.quadInk)
      Spacer(minLength: 0)
      if own {
        NavigationLink("Manage listing") { ListingManageView(listing: listing) }
          .buttonStyle(.quadPrimary)
      } else {
        Button("Message \(QuadFormat.firstName(listing.hostName))") {
          Task { await state.contact(listingID: listing.id) }
        }
        .buttonStyle(.quadPrimary)
      }
    }
    .padding(.leading, 20).padding(.trailing, 10).frame(minHeight: 72)
    .background(.white, in: Capsule())
    .shadow(color: Color(quad: 0x1F2937).opacity(0.12), radius: 14, y: 6)
    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
    .quadBarFade()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("listing-price-bar")
  }

  /// Finds a published tour to offer on the photo. A server without tours simply has none.
  private func loadTour() async {
    let response: ToursResponse? = try? await state.api.get("/api/listings/\(listing.id)/tours")
    tour = response?.tours.first { $0.status == "ready" && $0.published }
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
            Task { if await state.signedInOrAsk() { report = true } }
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
