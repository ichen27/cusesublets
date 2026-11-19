import SwiftUI

/// Matches for one of the signed-in person's plans, one at a time: a place that fits their
/// housing search, or a person whose search fits one of their places. Each card says why it
/// fits and offers Pass, Save for later and Message. The server decides what matches.
struct MatchesView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var mine: [Listing] = []
  @State private var search: HousingSearch?
  /// "search:<id>" or "listing:<id>": the plan whose matches are showing.
  @State private var plan = ""
  @State private var matches: [MatchItem] = []
  @State private var deck = MatchDeck(ids: [])
  @State private var loading = true
  @State private var busy = false
  @State private var error = ""
  @State private var notice = ""
  @State private var hasTour = false
  @State private var drag: CGFloat = 0
  @State private var opened: Opened?
  private let store = MatchSeenStore()

  /// A screen opened from the card.
  private enum Opened: Hashable {
    case place(String)
    case person(String)
    case member(String)
  }

  private struct Plan: Identifiable {
    let id: String
    let menuTitle: String
    let chip: String
  }

  private var plans: [Plan] {
    var all: [Plan] = []
    if let search, search.status == "active" {
      all.append(
        Plan(
          id: "search:" + search.id, menuTitle: "My housing search",
          chip: MatchText.planLabel(search: true, title: "")))
    }
    for place in mine where place.status == "approved" {
      all.append(
        Plan(
          id: "listing:" + place.id, menuTitle: place.title,
          chip: MatchText.planLabel(search: false, title: place.title)))
    }
    return all
  }
  private var planIsSearch: Bool { plan.hasPrefix("search:") }
  /// The signed-in person's own place, when the matches are for a place.
  private var myPlace: Listing? { mine.first { "listing:" + $0.id == plan } }
  private var current: MatchItem? { deck.current.flatMap { id in matches.first { $0.id == id } } }

  var body: some View {
    Group {
      if state.checkingSavedSession {
        CheckingSessionView()
      } else if state.user == nil {
        message(
          symbol: "person.2", title: "Find your fit",
          text:
            "Log in, then say what you're looking for or list your place. Quad lines up the ones that fit."
        ) {
          Button("Log in") { state.showLogin = true }.buttonStyle(.quadPrimaryWide)
        }
      } else {
        VStack(spacing: 0) {
          header
          content
        }
      }
    }
    // The tab bar floats over the bottom of this screen. The card scrolls on its own above
    // the action buttons, so the whole screen stops short of the bar.
    .padding(.bottom, QuadTabBar.reservedHeight)
    .foregroundStyle(Color.quadInk)
    .background(Color.quadGround.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .task(id: state.user?.id) {
      // Runs again each time this tab comes back, so matches stay current. Choosing a
      // different plan reloads through the task below.
      let before = plan
      await loadPlans()
      if plan == before { await loadMatches() }
    }
    .task(id: plan) { await loadMatches() }
    .task(id: deck.current) { await lookForTour() }
    .navigationDestination(item: $opened) { screen in
      switch screen {
      case .place(let id):
        if let place = matches.first(where: { $0.listing?.id == id })?.listing {
          ListingView(listing: place)
        }
      case .person(let id):
        if let person = matches.first(where: { $0.search?.id == id })?.search {
          SearchDetailView(search: person)
        }
      case .member(let id):
        MemberView(id: id)
      }
    }
  }

  // MARK: Frame

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Matches").font(.largeTitle.weight(.heavy)).accessibilityAddTraits(.isHeader)
        Spacer()
        if deck.canGoBack {
          Button {
            change { deck.goBack() }
          } label: {
            Image(systemName: "arrow.uturn.backward")
          }
          .buttonStyle(.quadIcon).accessibilityLabel("Back to the last match")
        }
      }
      if let shown = plans.first(where: { $0.id == plan }) {
        HStack {
          if plans.count > 1 {
            Menu {
              ForEach(plans) { option in Button(option.menuTitle) { plan = option.id } }
            } label: {
              planChip(shown.chip, menu: true)
            }
            .accessibilityLabel("Matches \(shown.chip). Change")
          } else {
            planChip(shown.chip, menu: false)
          }
          Spacer(minLength: 8)
          Text(MatchText.position(deck)).font(.footnote.weight(.bold))
            .foregroundStyle(Color.quadMuted).accessibilityIdentifier("match-position")
        }
      }
    }
    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
  }

  private func planChip(_ text: String, menu: Bool) -> some View {
    HStack(spacing: 5) {
      Text(text).lineLimit(1)
      if menu { Image(systemName: "chevron.down").imageScale(.small) }
    }
    .font(.subheadline.weight(.bold)).foregroundStyle(Color.quadInk)
    .padding(.horizontal, 14).frame(minHeight: 38)
    .background(.white, in: Capsule())
    .overlay(Capsule().strokeBorder(Color.quadInk.opacity(0.08)))
  }

  @ViewBuilder private var content: some View {
    if !error.isEmpty {
      message(symbol: "wifi.exclamationmark", title: "Matches didn't load", text: error) {
        Button("Try again") {
          Task {
            await loadPlans()
            await loadMatches()
          }
        }.buttonStyle(QuadSecondaryButtonStyle(wide: true))
      }
    } else if loading {
      Spacer()
      ProgressView()
      Spacer()
    } else if plan.isEmpty {
      message(
        symbol: "sparkles", title: "Matches start with your plans",
        text:
          "Say what you're looking for, or list your place. A match has to fit the dates, the budget, the area and the must-haves."
      ) {
        Button("Say what I'm looking for") { post(.search) }.buttonStyle(.quadPrimaryWide)
        Button("Sublease my place") { post(.listing) }
          .buttonStyle(QuadSecondaryButtonStyle(wide: true))
      }
    } else if let item = current {
      card(item)
      actions(item)
    } else if deck.isFinished {
      message(
        symbol: "checkmark", title: seenAllTitle,
        text: "That is everyone who fits right now. New matches show up here as people post."
      ) {
        Button("Start again") { change { deck.startAgain() } }
          .buttonStyle(QuadSecondaryButtonStyle(wide: true))
      }
    } else if planIsSearch {
      message(
        symbol: "magnifyingglass", title: "Nothing fits yet",
        text:
          "No place covers your dates, budget, area and must-haves right now. Loosening one of them shows more."
      ) {
        Button("Change what I'm looking for") { post(.search) }
          .buttonStyle(QuadSecondaryButtonStyle(wide: true))
      }
    } else {
      message(
        symbol: "magnifyingglass", title: "Nobody fits yet",
        text: "Nobody looking right now fits this place's dates, rent and area."
      ) { EmptyView() }
    }
  }

  private var seenAllTitle: String {
    deck.total == 1 ? "You've seen the 1 that fits" : "You've seen all \(deck.total)"
  }

  private func message<Buttons: View>(
    symbol: String, title: String, text: String, @ViewBuilder buttons: () -> Buttons
  ) -> some View {
    VStack(spacing: 14) {
      Spacer()
      Image(systemName: symbol).font(.title.weight(.semibold))
        .foregroundStyle(Color.quadGreenText).frame(width: 76, height: 76)
        .background(Color.quadGreenTint, in: Circle()).accessibilityHidden(true)
      Text(title).font(.title2.weight(.heavy)).multilineTextAlignment(.center)
      Text(text).foregroundStyle(Color.quadMuted).multilineTextAlignment(.center)
      buttons()
      Spacer()
    }
    .padding(.horizontal, 28)
    .frame(maxWidth: .infinity)
  }

  // MARK: Card

  private func card(_ item: MatchItem) -> some View {
    GeometryReader { space in
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if let place = item.listing {
            placeCard(place)
          } else if let person = item.search {
            personCard(person)
          }
          why(item)
        }
        .padding(12)
        .quadCard(radius: 28)
        .overlay(alignment: drag < 0 ? .topTrailing : .topLeading) {
          if let label = dragLabel(width: space.size.width) {
            QuadChip(text: label, kind: .dark).padding(22)
          }
        }
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 16)
      }
      // The tab's scrolling screens keep room for the tab bar under their content. This one
      // already ends above its own buttons.
      .contentMargins(.bottom, 0, for: .scrollContent)
      .refreshable {
        await loadPlans()
        await loadMatches()
      }
      .offset(x: drag)
      .rotationEffect(.degrees(reduceMotion ? 0 : Double(drag) / 28), anchor: .bottom)
      .simultaneousGesture(
        DragGesture(minimumDistance: 24)
          .onChanged { value in
            // Only a mostly sideways drag moves the card, so scrolling it stays easy.
            if abs(value.translation.width) > abs(value.translation.height) * 1.5 {
              drag = value.translation.width
            }
          }
          .onEnded { value in
            // Judged from where the finger lifted, so a quick flick counts as well as a slow
            // drag.
            let across = value.translation.width
            let sideways = abs(across) > abs(value.translation.height) * 1.5
            let choice =
              sideways ? MatchSwipe.choice(translation: across, width: space.size.width) : nil
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
              drag = 0
            }
            switch choice {
            case .pass: pass()
            case .save: save(item)
            case nil: break
            }
          }
      )
    }
    .id(item.id)
    .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
  }

  /// What letting go of the card now would do, shown once the drag is far enough to count.
  private func dragLabel(width: CGFloat) -> String? {
    switch MatchSwipe.choice(translation: drag, width: width) {
    case .pass: return "Pass"
    case .save: return "Save for later"
    case nil: return nil
    }
  }

  /// Part of the card that opens another screen when tapped. It is not a button: the card
  /// follows a dragging finger, and a button under that finger would count the lift as a tap.
  private func opens<Content: View>(
    _ screen: Opened, hint: String, @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .foregroundStyle(Color.quadInk)
      .contentShape(Rectangle())
      .onTapGesture { opened = screen }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isButton)
      .accessibilityHint(hint)
      .accessibilityAction { opened = screen }
  }

  @ViewBuilder private func placeCard(_ place: Listing) -> some View {
    opens(.place(place.id), hint: "Opens the place") {
      VStack(alignment: .leading, spacing: 12) {
        RemoteImage(path: place.images.first)
          .frame(height: 230).frame(maxWidth: .infinity)
          .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
          .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
              if place.sample { QuadChip(text: "Sample", kind: .dark) }
              if hasTour { QuadChip(text: "360° tour", symbol: "view.3d", kind: .dark) }
            }.padding(10)
          }
          .overlay(alignment: .bottomLeading) {
            QuadChip(text: dollars(place.price) + " / mo", kind: .price).padding(10)
          }
        VStack(alignment: .leading, spacing: 4) {
          Text(place.title).font(.title3.weight(.heavy)).multilineTextAlignment(.leading)
          Label(place.neighborhood, systemImage: "mappin.and.ellipse")
            .font(.footnote.weight(.semibold))
          Text(
            QuadFormat.stay(
              roomType: place.roomType, beds: place.beds, baths: place.baths,
              start: place.startDate, end: place.endDate)
          ).font(.footnote).foregroundStyle(Color.quadMuted).multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    opens(.member(place.ownerId), hint: "Opens this person's profile") {
      HStack(spacing: 10) {
        QuadAvatar(name: place.hostName, id: place.ownerId)
        VStack(alignment: .leading, spacing: 2) {
          Text(place.hostName).font(.subheadline.weight(.heavy))
          Text(MatchText.checks(identity: place.hostIdentity, lease: place.leaseStatus))
            .font(.footnote).foregroundStyle(Color.quadMuted)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.footnote.weight(.bold))
          .foregroundStyle(Color.quadMuted)
      }
      .padding(.horizontal, 4)
    }
  }

  @ViewBuilder private func personCard(_ person: HousingSearch) -> some View {
    opens(.person(person.id), hint: "Opens what this person is looking for") {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          QuadAvatar(name: person.ownerName, id: person.ownerId, size: 64)
          VStack(alignment: .leading, spacing: 3) {
            Text(person.ownerName).font(.title3.weight(.heavy))
            Text("Looking for a place").font(.footnote).foregroundStyle(Color.quadMuted)
            if person.ownerIdentity == "verified" {
              QuadChip(text: "ID checked", symbol: "checkmark.shield", kind: .good)
            } else {
              Text("ID not checked").font(.footnote).foregroundStyle(Color.quadMuted)
            }
          }
          Spacer(minLength: 0)
        }
        if !person.introduction.isEmpty {
          Text(person.introduction).font(.subheadline).multilineTextAlignment(.leading)
        }
        QuadFlow {
          QuadChip(text: "Up to " + dollars(person.maxBudget))
          QuadChip(text: QuadFormat.dateRange(person.startDate, person.endDate))
          if person.roomType != "Any" { QuadChip(text: person.roomType) }
          ForEach(person.areas.prefix(3)) { QuadChip(text: $0.label) }
        }
      }
      .padding(.horizontal, 4).padding(.top, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func why(_ item: MatchItem) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(planIsSearch ? "Why it fits your search" : "Why your place fits")
        .font(.subheadline.weight(.heavy))
      ForEach(reasons(for: item), id: \.self) { reason in
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "checkmark").font(.footnote.weight(.heavy))
            .foregroundStyle(Color.quadGreen).frame(width: 18, alignment: .leading)
          Text(reason).font(.subheadline)
        }
      }
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.quadWell, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  /// Reasons with the person's own numbers in them. Without both sides to hand, the server's
  /// plainer wording is shown.
  private func reasons(for item: MatchItem) -> [String] {
    if let place = item.listing, let search {
      return MatchText.reasons(listing: place, search: search, for: .seeker)
    }
    if let person = item.search, let myPlace {
      return MatchText.reasons(
        listing: myPlace, search: person, for: .host(seeker: person.ownerName))
    }
    return item.reasons
  }

  private func actions(_ item: MatchItem) -> some View {
    let name = QuadFormat.firstName(item.listing?.hostName ?? item.search?.ownerName ?? "")
    return VStack(spacing: 6) {
      if !notice.isEmpty {
        Text(notice).font(.footnote.weight(.semibold)).foregroundStyle(Color.quadGreenText)
          .accessibilityIdentifier("match-notice")
      }
      HStack(spacing: 12) {
        Button {
          pass()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.quadIcon).accessibilityLabel("Pass")
        Button {
          save(item)
        } label: {
          Image(systemName: "bookmark")
        }
        .buttonStyle(.quadIcon).accessibilityLabel("Save for later")
        Button("Message \(name)") { message(item) }.buttonStyle(.quadPrimaryWide)
      }
      .disabled(busy)
    }
    .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 4)
  }

  // MARK: Actions

  /// Changes the deck, remembers what has been seen, and animates the next card in.
  private func change(_ edit: () -> Void) {
    withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)) { edit() }
    if let user = state.user?.id, !plan.isEmpty {
      store.save(deck.seen, user: user, plan: plan)
    }
  }

  private func pass() {
    notice = ""
    change { deck.moveOn() }
  }

  private func save(_ item: MatchItem) {
    guard !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        let kind = item.listing == nil ? "search" : "listing"
        try await state.api.act("/api/social/\(kind)/\(item.id)/save", ["saved": true])
        change { deck.moveOn() }
        notice = "Saved. It is under Saved posts in You."
      } catch { state.error = error.localizedDescription }
    }
  }

  private func message(_ item: MatchItem) {
    guard !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      if let place = item.listing {
        await state.contact(listingID: place.id)
      } else if let person = item.search, let myPlace {
        await state.contact(listingID: myPlace.id, searchID: person.id)
      }
      // A conversation that opened takes the person to the Inbox. The deck moves on behind
      // them, so coming back shows the next match.
      if state.tab == QuadTab.inbox.rawValue {
        notice = ""
        change { deck.moveOn() }
      }
    }
  }

  private func post(_ intent: PostIntent) {
    state.postIntent = intent
    state.tab = QuadTab.you.rawValue
  }

  private func loadPlans() async {
    guard state.user != nil else {
      mine = []
      search = nil
      plan = ""
      matches = []
      deck = MatchDeck(ids: [])
      return
    }
    do {
      let places: ListingsResponse = try await state.api.get("/api/mine")
      mine = places.listings
      let own: MySearchResponse = try await state.api.get("/api/my-search")
      search = own.search
      error = ""
      if !plans.contains(where: { $0.id == plan }) {
        // Changing `plan` reloads the matches. With no plan there is nothing more to load.
        plan = plans.first?.id ?? ""
        if plan.isEmpty { loading = false }
      }
    } catch {
      self.error = error.localizedDescription
      loading = false
    }
  }

  private func loadMatches() async {
    guard let user = state.user?.id, !plan.isEmpty else {
      matches = []
      deck = MatchDeck(ids: [])
      return
    }
    loading = matches.isEmpty
    do {
      let parts = plan.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { return }
      let found: MatchesResponse = try await state.api.get(
        "/api/matches?sourceType=\(parts[0])&sourceId=\(parts[1])")
      try Task.checkCancellation()
      let visible = found.matches.filter {
        !state.hiddenMemberIDs.contains($0.listing?.ownerId ?? $0.search?.ownerId ?? "")
      }
      matches = visible
      deck = MatchDeck(ids: visible.map(\.id), seen: store.seen(user: user, plan: plan))
      error = ""
      loading = false
    } catch is CancellationError {
      // Another plan was chosen; its own load ends the waiting.
    } catch {
      self.error = error.localizedDescription
      loading = false
    }
  }

  private func lookForTour() async {
    hasTour = false
    guard let place = current?.listing else { return }
    guard
      let tours: ToursResponse = try? await state.api.get("/api/listings/\(place.id)/tours")
    else { return }
    hasTour = tours.tours.contains { $0.published && $0.status == "ready" }
  }
}
