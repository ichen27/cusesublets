import MapKit
import SwiftUI

/// Someone's housing search: who is looking, what for and where, with comments. Its own bar at
/// the bottom offers them a place of yours that fits, which is how a conversation with someone
/// looking starts.
struct SearchDetailView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) private var dismiss
  let search: HousingSearch
  /// The viewer's places that fit this search.
  @State private var fitting: [Listing] = []
  @State private var ready = false
  @State private var choosing = false
  @State private var report = false
  @State private var reason = ""

  private var own: Bool { state.user?.id == search.ownerId }
  private var hidden: Bool { state.hiddenMemberIDs.contains(search.ownerId) }
  private var first: String { QuadFormat.firstName(search.ownerName) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        topBar
        if hidden {
          Text("This member’s content is hidden while you are signed in.")
            .font(.subheadline).foregroundStyle(Color.quadMuted)
        } else {
          Text(own ? "What you're looking for" : "\(first) is looking for a place")
            .font(.title2.weight(.heavy)).accessibilityAddTraits(.isHeader)
          person
          facts
          if !search.introduction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              caption(own ? "In your words" : "In \(first)'s words")
              Text(search.introduction).font(.subheadline)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).quadCard(radius: 22)
          }
          Map {
            ForEach(search.areas) { area in
              MapPolygon(
                coordinates: area.points.map {
                  CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
                }
              ).foregroundStyle(Color.quadOrange.opacity(0.25))
            }
          }
          .frame(height: 220)
          .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
          .accessibilityLabel("Map of where \(own ? "you are" : first + " is") looking")
          SocialView(type: "search", targetID: search.id)
        }
      }
      .padding(.horizontal, 16).padding(.bottom, 16)
    }
    // This screen has no tab bar under it, so it drops the room the tab reserves for one.
    .contentMargins(.bottom, 0, for: .scrollContent)
    .foregroundStyle(Color.quadInk)
    .background(Color.quadGround.ignoresSafeArea())
    .safeAreaInset(edge: .bottom, spacing: 0) { if !hidden && !own { replyBar } }
    .toolbar(.hidden, for: .navigationBar)
    .hidesQuadTabBar()
    .confirmationDialog("Which place?", isPresented: $choosing, titleVisibility: .visible) {
      ForEach(fitting) { place in
        Button("Offer \(place.title)") { offer(place) }
      }
    }
    .alert("Report this search", isPresented: $report) {
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
      ready = false
      fitting = []
      if state.user != nil, !own {
        do {
          let r: ListingsResponse = try await state.api.get("/api/mine")
          fitting = r.listings.filter { housingFits($0, search) }
        } catch { state.error = error.localizedDescription }
      }
      ready = true
    }
  }

  // MARK: Parts

  private var topBar: some View {
    HStack {
      Button {
        dismiss()
      } label: {
        Image(systemName: "chevron.left")
      }
      .buttonStyle(.quadIcon).accessibilityLabel("Back")
      Spacer()
      if !own && !hidden {
        Menu {
          Button("Report this search", systemImage: "flag", role: .destructive) {
            Task { if await state.signedInOrAsk() { report = true } }
          }
        } label: {
          Image(systemName: "ellipsis").font(.body.weight(.semibold))
            .foregroundStyle(Color.quadInk).frame(width: 44, height: 44)
            .background(.white, in: Circle())
            .overlay(Circle().strokeBorder(Color.quadInk.opacity(0.08)))
        }
        .accessibilityLabel("More: report")
      }
    }
    .padding(.top, 4)
  }

  private var person: some View {
    NavigationLink {
      MemberView(id: search.ownerId)
    } label: {
      HStack(spacing: 12) {
        QuadAvatar(name: search.ownerName, id: search.ownerId, size: 48)
        VStack(alignment: .leading, spacing: 4) {
          Text(search.ownerName).font(.headline.weight(.heavy))
          QuadChip(
            text: search.ownerIdentity == "verified" ? "ID checked" : "ID not checked",
            symbol: search.ownerIdentity == "verified" ? "checkmark.shield.fill" : "shield",
            kind: search.ownerIdentity == "verified" ? .good : .plain)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.footnote.weight(.bold))
          .foregroundStyle(Color.quadMuted)
      }
      .padding(14).quadCard(radius: 22).contentShape(Rectangle())
    }
    .buttonStyle(.plain).accessibilityElement(children: .ignore)
    .accessibilityLabel("About \(search.ownerName)").accessibilityAddTraits(.isButton)
  }

  private var facts: some View {
    // What they wrote about themselves has its own card below.
    var rows = SearchText.rows(search).filter { $0.step != .about }
    if !search.preferredAmenities.isEmpty {
      rows.append(
        .init(
          title: "Nice to have", value: search.preferredAmenities.joined(separator: ", "),
          step: .place))
    }
    return VStack(spacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
        VStack(alignment: .leading, spacing: 2) {
          caption(row.title)
          Text(row.value).font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        if index < rows.count - 1 { Divider().padding(.leading, 16) }
      }
    }
    .quadCard(radius: 22)
  }

  @ViewBuilder private var replyBar: some View {
    VStack(spacing: 8) {
      if state.user == nil {
        Button("Log in to reply") { state.showLogin = true }.buttonStyle(.quadPrimaryWide)
      } else if !ready {
        EmptyView()
      } else if fitting.isEmpty {
        Text(
          "A conversation here is about a place. To message \(first), list a place that fits what they are looking for."
        )
        .font(.footnote).foregroundStyle(Color.quadMuted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("search-reply-unavailable")
      } else {
        Button(fitting.count == 1 ? "Offer \(fitting[0].title)" : "Offer a place") {
          if fitting.count == 1 { offer(fitting[0]) } else { choosing = true }
        }
        .buttonStyle(.quadPrimaryWide)
      }
    }
    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    .quadBarFade()
  }

  private func caption(_ text: String) -> some View {
    Text(text).font(.caption.weight(.bold)).foregroundStyle(Color.quadMuted)
  }

  private func offer(_ place: Listing) {
    Task { await state.contact(listingID: place.id, searchID: search.id) }
  }
}
