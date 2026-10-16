import MapKit
import SwiftUI

struct BrowseView: View {
  @EnvironmentObject var state: AppState
  @State private var listings: [Listing] = []
  @State private var searches: [HousingSearch] = []
  @State private var query = ""
  @State private var kind = "All"
  @State private var error = ""
  @State private var maximum = 3000.0
  @State private var showMap = false
  @State private var loading = true
  var filtered: [Listing] {
    listings.filter {
      $0.price <= maximum
        && (query.isEmpty
          || ($0.title + " " + $0.neighborhood).localizedCaseInsensitiveContains(query))
    }
  }
  var people: [HousingSearch] {
    searches.filter {
      query.isEmpty
        || ($0.ownerName + " " + $0.introduction + " "
          + $0.areas.map(\.label).joined(separator: " ")).localizedCaseInsensitiveContains(query)
    }
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Find a sublet.\nList your place.").font(.largeTitle.bold())
          Text("Homes and people around Syracuse.").foregroundStyle(.secondary)
        }.padding(.top, 8)
        Picker("Browse", selection: $kind) {
          ForEach(["All", "Places", "People"], id: \.self) { Text($0) }
        }.pickerStyle(.segmented)
        if kind != "People" {
          HStack {
            Text("Up to \(dollars(maximum))/mo")
            Spacer()
            Button(showMap ? "Hide map" : "Show map", systemImage: "map") { showMap.toggle() }
          }.font(.subheadline)
          Slider(value: $maximum, in: 100...5000, step: 50).accessibilityLabel(
            "Maximum monthly rent")
          if showMap {
            Map {
              ForEach(filtered) { l in
                Annotation(l.title, coordinate: l.coordinate) {
                  NavigationLink {
                    ListingView(listing: l)
                  } label: {
                    Text(dollars(l.price)).font(.caption.bold()).padding(6).background(
                      .white, in: Capsule())
                  }
                }
              }
            }.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 18))
          }
        }
        if !error.isEmpty {
          Text(error).foregroundStyle(.red)
          Button("Retry") { Task { await load() } }
        }
        if loading { ProgressView().frame(maxWidth: .infinity) }
        if kind != "People" {
          ForEach(filtered) { l in
            NavigationLink {
              ListingView(listing: l)
            } label: {
              ListingCard(listing: l)
            }.buttonStyle(.plain)
          }
        }
        if kind != "Places" {
          ForEach(people) { s in
            NavigationLink {
              SearchDetailView(search: s)
            } label: {
              SearchCard(search: s)
            }.buttonStyle(.plain)
          }
        }
        if !loading && error.isEmpty && (kind == "People" || filtered.isEmpty)
          && (kind == "Places" || people.isEmpty)
        {
          EmptyState(title: "No posts match", text: "Try a different neighborhood or budget.")
        }
      }.padding()
    }.background(Color.cuseCream.opacity(0.45))
      .navigationTitle("CuseSublets").navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, prompt: "Neighborhood, home or person")
      .toolbar {
        Button {
          state.tab = 3
        } label: {
          Image(systemName: "plus.circle.fill")
        }.accessibilityLabel("Post a place or housing search")
      }
      .task { await load() }.refreshable { await load() }
  }
  func load() async {
    loading = true
    defer { loading = false }
    do {
      async let l: ListingsResponse = state.api.get("/api/listings")
      async let s: SearchesResponse = state.api.get("/api/searches")
      (listings, searches) = try await (l.listings, s.searches)
      error = ""
    } catch { self.error = error.localizedDescription }
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
          Map { Marker(listing.neighborhood, coordinate: listing.coordinate) }.frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 16))
          Text("Approximate location · \(listing.address)").font(.caption).foregroundStyle(
            .secondary)
          if let tour = listing.matterportUrl, let url = URL(string: tour), url.scheme == "https" {
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
          SocialView(type: "listing", targetID: listing.id)
          if state.user?.id != listing.ownerId {
            Button("Contact host") { Task { await state.contact(listingID: listing.id) } }
              .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
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
  var body: some View {
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
          if mine.isEmpty {
            Text("To contact this person, publish a matching listing and use Matches.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(mine) { listing in
              Button("Offer: \(listing.title)") {
                Task { await state.contact(listingID: listing.id, searchID: search.id) }
              }
            }
          }
        }
      }.padding()
    }.navigationTitle("Housing search").task {
      if state.user != nil {
        do {
          let r: ListingsResponse = try await state.api.get("/api/mine")
          mine = r.listings.filter { $0.status == "approved" }
        } catch { state.error = error.localizedDescription }
      }
    }
  }
}
struct MemberView: View {
  @EnvironmentObject var state: AppState
  let id: String
  @State private var detail: PublicProfileResponse?
  var body: some View {
    ScrollView {
      if let d = detail {
        VStack(alignment: .leading, spacing: 16) {
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
          ForEach(d.listings) { l in
            NavigationLink {
              ListingView(listing: l)
            } label: {
              ListingCard(listing: l)
            }.buttonStyle(.plain)
          }
          ForEach(d.reviews) { r in
            VStack(alignment: .leading) {
              Text("\(r.rating)/5 · \(r.authorName)").bold()
              Text(r.body)
            }
          }
        }.padding()
      } else {
        ProgressView()
      }
    }.navigationTitle("Member").task {
      do { detail = try await state.api.get("/api/users/\(id)") } catch {
        state.error = error.localizedDescription
      }
    }
  }
}
