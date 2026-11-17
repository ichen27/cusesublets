import SwiftUI

/// A person's public profile: who they are, what staff have checked, what they have finished
/// here, their places, what they are looking for and their reviews. Its own bar at the bottom
/// starts a conversation, which is always about a place.
struct MemberView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) private var dismiss
  let id: String
  @State private var detail: PublicProfileResponse?
  /// The viewer's own places, read only when this person is looking for one.
  @State private var mine: [Listing] = []
  /// False until everything the message choices depend on has arrived.
  @State private var ready = false
  @State private var error = ""
  @State private var choosing = false
  @State private var bookingID = ""
  @State private var rating = 5
  @State private var review = ""
  @State private var busy = false
  @State private var notice = ""

  private var own: Bool { state.user?.id == id }
  private var hidden: Bool { state.hiddenMemberIDs.contains(id) }

  private var choices: [PersonMessageChoice] {
    guard let detail, ready else { return [] }
    return PersonMessage.choices(
      viewerID: state.user?.id, personID: id, theirPlaces: detail.listings,
      theirSearch: detail.search, myPlaces: mine)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        topBar
        if hidden {
          Text("This member’s profile, places and comments are hidden while you are signed in.")
            .font(.subheadline).foregroundStyle(Color.quadMuted)
        } else if let detail {
          profile(detail)
        } else if error.isEmpty {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
        }
        if !error.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text(error).font(.subheadline).foregroundStyle(Color.quadInk)
            Button("Try again") { Task { await load() } }.buttonStyle(.quadSecondary)
          }
        }
      }
      .padding(.horizontal, 16).padding(.bottom, 16)
    }
    // This screen has no tab bar under it, so it drops the room the tab reserves for one.
    .contentMargins(.bottom, 0, for: .scrollContent)
    .background(Color.quadGround)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let detail, !hidden, !choices.isEmpty { messageBar(detail) }
    }
    .toolbar(.hidden, for: .navigationBar)
    .hidesQuadTabBar()
    .task(id: state.user?.id) {
      detail = nil
      review = ""
      notice = ""
      await load()
    }
    .refreshable { await load() }
    .confirmationDialog("What is your message about?", isPresented: $choosing, titleVisibility: .visible) {
      ForEach(choices) { choice in
        Button(choice.label) { start(choice) }
      }
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
      MemberSafetyActions(memberID: id, menu: true)
    }
    .padding(.top, 4)
  }

  @ViewBuilder private func profile(_ d: PublicProfileResponse) -> some View {
    let first = QuadFormat.firstName(d.profile.name)
    if own { ownNote }
    header(d)
    stats(d)
    if !d.profile.bio.isEmpty {
      Text(d.profile.bio).font(.subheadline).foregroundStyle(Color.quadInk)
    }
    if !d.profile.photos.isEmpty { photos(d.profile.photos) }
    links(d.profile.socials)
    if !d.listings.isEmpty {
      section(PersonText.placesHeading(name: d.profile.name, count: d.listings.count)) {
        ForEach(d.listings) { place($0) }
      }
    }
    if let search = d.search {
      section("What \(first) is looking for") { looking(search) }
    }
    section("Reviews") {
      Text("Only someone who finished a sublease with \(first) here can write one.")
        .font(.caption).foregroundStyle(Color.quadMuted)
      if d.reviews.isEmpty {
        Text("No reviews yet.").font(.subheadline).foregroundStyle(Color.quadMuted)
      }
      ForEach(d.reviews) { reviewCard($0) }
    }
    if !d.reviewableBookings.isEmpty { reviewForm(d, first: first) }
    if !notice.isEmpty {
      Text(notice).font(.subheadline.weight(.semibold)).foregroundStyle(Color.quadGreenText)
    }
    if ready, !own, choices.isEmpty {
      Text(PersonMessage.unavailable(name: d.profile.name, looking: d.search != nil))
        .font(.footnote).foregroundStyle(Color.quadMuted)
        .accessibilityIdentifier("person-message-unavailable")
    }
  }

  private var ownNote: some View {
    HStack(spacing: 10) {
      Text("This is your profile as other people see it.").font(.footnote.weight(.semibold))
      Spacer(minLength: 0)
      NavigationLink("Edit") { ProfileEditor() }.buttonStyle(.quadSecondary)
    }
    .foregroundStyle(Color.quadInk)
    .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
    .background(Color.quadWell, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }

  private func header(_ d: PublicProfileResponse) -> some View {
    HStack(alignment: .center, spacing: 14) {
      if d.profile.avatar != nil {
        RemoteImage(path: d.profile.avatar).frame(width: 88, height: 88).clipShape(Circle())
          .accessibilityHidden(true)
      } else {
        QuadAvatar(name: d.profile.name, id: d.profile.id, size: 88)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(d.profile.name).font(.title2.weight(.heavy)).foregroundStyle(Color.quadInk)
          .accessibilityAddTraits(.isHeader)
        if let since = PersonText.memberSince(d.profile.joinedAt) {
          Text(since).font(.footnote).foregroundStyle(Color.quadMuted)
        }
        QuadFlow {
          if d.profile.identity == "verified" {
            QuadChip(text: "ID checked", symbol: "checkmark.shield", kind: .good)
          } else {
            QuadChip(text: "ID not checked")
          }
          ForEach(
            PersonText.roles(places: d.listings.count, looking: d.search != nil), id: \.self
          ) { QuadChip(text: $0, kind: .note) }
        }
      }
    }
  }

  private func stats(_ d: PublicProfileResponse) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        if let rating = PersonText.rating(d.reviews.map(\.rating)) {
          stat(rating.value, rating.caption, star: true)
        } else {
          stat("0", "reviews yet")
        }
        if let done = d.completed {
          stat("\(done.subleaser)", "as subleaser")
          stat("\(done.subtenant)", "as subtenant")
        }
      }
      if d.completed != nil {
        Text("Counted when a sublease booked here was paid for, moved into and has ended.")
          .font(.caption).foregroundStyle(Color.quadMuted)
      }
    }
  }

  private func stat(_ value: String, _ caption: String, star: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        if star {
          Image(systemName: "star.fill").font(.subheadline).foregroundStyle(Color.quadOrange)
            .accessibilityHidden(true)
        }
        Text(value).font(.title3.weight(.heavy))
      }
      Text(caption).font(.caption).foregroundStyle(Color.quadMuted)
    }
    .foregroundStyle(Color.quadInk)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .quadCard(radius: 20)
    .accessibilityElement(children: .combine)
  }

  private func photos(_ paths: [String]) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        ForEach(paths, id: \.self) {
          RemoteImage(path: $0).frame(width: 220, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
      }
    }
    .quadSidewaysScroll()
  }

  /// Links the person added. Only secure web links are offered.
  @ViewBuilder private func links(_ socials: [String: String]) -> some View {
    let safe = socials.keys.sorted().compactMap { key -> (String, URL)? in
      guard let value = socials[key], let url = URL(string: value), url.scheme == "https"
      else { return nil }
      return (key.capitalized, url)
    }
    if !safe.isEmpty {
      VStack(spacing: 0) {
        ForEach(Array(safe.enumerated()), id: \.offset) { index, link in
          if index > 0 { Divider().padding(.leading, 16) }
          Link(destination: link.1) {
            HStack {
              Text(link.0).font(.subheadline.weight(.bold))
              Spacer()
              Image(systemName: "arrow.up.right").font(.footnote.weight(.bold))
                .foregroundStyle(Color.quadMuted)
            }
            .foregroundStyle(Color.quadInk)
            .padding(.horizontal, 16).frame(minHeight: 52)
            .contentShape(Rectangle())
          }
        }
      }
      .quadCard()
    }
  }

  private func section<Content: View>(
    _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline.weight(.heavy)).foregroundStyle(Color.quadInk)
        .accessibilityAddTraits(.isHeader)
      content()
    }
  }

  private func place(_ listing: Listing) -> some View {
    NavigationLink {
      ListingView(listing: listing)
    } label: {
      HStack(spacing: 12) {
        RemoteImage(path: listing.images.first).frame(width: 72, height: 72)
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(listing.title).font(.subheadline.weight(.heavy)).lineLimit(2)
            .multilineTextAlignment(.leading)
          Text(
            "\(listing.neighborhood) · \(QuadFormat.dateRange(listing.startDate, listing.endDate))"
          ).font(.footnote).foregroundStyle(Color.quadMuted)
          (Text(dollars(listing.price)).font(.callout.weight(.heavy))
            + Text(" / month").font(.caption.weight(.bold)).foregroundColor(.quadMuted))
        }
        Spacer(minLength: 0)
      }
      .foregroundStyle(Color.quadInk)
      .padding(10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .quadCard()
  }

  private func looking(_ search: HousingSearch) -> some View {
    NavigationLink {
      SearchDetailView(search: search)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Text(PersonText.looking(search)).font(.subheadline.weight(.heavy))
        Text(
          (search.areas.map(\.label)
            + [QuadFormat.dateRange(search.startDate, search.endDate)]).joined(separator: " · ")
        ).font(.footnote).foregroundStyle(Color.quadMuted)
        if !search.introduction.isEmpty {
          Text(search.introduction).font(.subheadline).lineLimit(3)
            .multilineTextAlignment(.leading)
        }
      }
      .foregroundStyle(Color.quadInk)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .quadCard()
  }

  private func reviewCard(_ r: MemberReview) -> some View {
    let who = PersonText.reviewer(role: r.authorRole, stayEnded: r.stayEnded)
    return VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 10) {
        QuadAvatar(name: r.authorName, id: r.authorId ?? r.id, size: 34)
        VStack(alignment: .leading, spacing: 1) {
          Text(r.authorName).font(.subheadline.weight(.heavy))
          if !who.isEmpty { Text(who).font(.caption).foregroundStyle(Color.quadMuted) }
        }
        Spacer(minLength: 0)
        HStack(spacing: 3) {
          Image(systemName: "star.fill").font(.caption).foregroundStyle(Color.quadOrange)
          Text("\(r.rating)").font(.subheadline.weight(.heavy))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(r.rating) out of 5")
      }
      Text(r.body).font(.subheadline)
    }
    .foregroundStyle(Color.quadInk)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .quadCard()
  }

  private func reviewForm(_ d: PublicProfileResponse, first: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Review \(first)").font(.headline.weight(.heavy))
      Picker("Sublease", selection: $bookingID) {
        ForEach(d.reviewableBookings) {
          Text($0.listingTitle + " · ended " + $0.endDate).tag($0.id)
        }
      }
      .tint(.quadOrangeDeep)
      HStack(spacing: 2) {
        ForEach(1...5, id: \.self) { value in
          Button {
            rating = value
          } label: {
            Image(systemName: value <= rating ? "star.fill" : "star").font(.title3)
              .foregroundStyle(value <= rating ? Color.quadOrange : Color.quadMuted)
              .frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(value) out of 5")
          .accessibilityAddTraits(value == rating ? [.isSelected] : [])
        }
      }
      TextField("How did it go? 10 to 2,000 characters", text: $review, axis: .vertical)
        .lineLimit(3...8).padding(12)
        .background(Color.quadWell, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      Button("Publish review") { Task { await publishReview() } }
        .buttonStyle(.quadSecondary)
        .disabled(
          busy || bookingID.isEmpty
            || review.trimmingCharacters(in: .whitespacesAndNewlines).count < 10
            || review.count > 2000)
    }
    .foregroundStyle(Color.quadInk)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .quadCard()
  }

  private func messageBar(_ d: PublicProfileResponse) -> some View {
    Button {
      if choices.count == 1, let only = choices.first { start(only) } else { choosing = true }
    } label: {
      Label("Message \(QuadFormat.firstName(d.profile.name))", systemImage: "bubble.left")
    }
    .buttonStyle(.quadPrimaryWide)
    .padding(.horizontal, 10).frame(minHeight: 72)
    .background(.white, in: Capsule())
    .shadow(color: Color(quad: 0x1F2937).opacity(0.12), radius: 14, y: 6)
    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
    .quadBarFade()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("person-message-bar")
  }

  // MARK: Doing

  private func start(_ choice: PersonMessageChoice) {
    Task { await state.contact(listingID: choice.listingID, searchID: choice.searchID) }
  }

  private func publishReview() async {
    busy = true
    defer { busy = false }
    do {
      try await state.api.act(
        "/api/users/\(id)/reviews", ["bookingId": bookingID, "rating": rating, "body": review])
      review = ""
      notice = "Review published"
      await load()
    } catch { self.error = error.localizedDescription }
  }

  private func load() async {
    do {
      let response: PublicProfileResponse = try await state.api.get("/api/users/\(id)")
      // Offering a place only applies to a signed-in person looking at someone who is
      // looking. Everyone else needs nothing more before the message choices are known.
      var places: [Listing] = []
      if response.search != nil, let viewer = state.user?.id, viewer != id {
        let own: ListingsResponse = try await state.api.get("/api/mine")
        places = own.listings
      }
      mine = places
      detail = response
      if !response.reviewableBookings.contains(where: { $0.id == bookingID }) {
        bookingID = response.reviewableBookings.first?.id ?? ""
      }
      ready = true
      error = ""
    } catch { self.error = error.localizedDescription }
  }
}
