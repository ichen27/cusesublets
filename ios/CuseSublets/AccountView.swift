import SwiftUI
import UniformTypeIdentifiers

/// The You tab: who you are here, what you are looking for, your places, and the account's
/// settings.
struct AccountView: View {
  @EnvironmentObject var state: AppState
  @State private var mine: [Listing] = []
  @State private var search: HousingSearch?
  @State private var listing: ListingFlowStart?
  @State private var newSearch = false
  @State private var error = ""
  @State private var drafts: [DraftRecord] = []
  @State private var loaded = false

  var body: some View {
    Group {
      if let user = state.user {
        signedIn(user)
      } else if state.checkingSavedSession {
        CheckingSessionView()
      } else {
        guest
      }
    }
    .foregroundStyle(Color.quadInk)
    .background(Color.quadGround.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .task(id: state.user?.id) { await load() }
    .onChange(of: state.postIntent, initial: true) { _, intent in
      // The Post button in the tab bar lands here; open the steps it asked for.
      guard let intent, state.user != nil else { return }
      state.postIntent = nil
      switch intent {
      case .listing: listing = .new()
      case .search: newSearch = true
      }
    }
    .fullScreenCover(item: $listing, onDismiss: { Task { await load() } }) { start in
      NavigationStack { ListingFlow(start: start, onSaved: { Task { await load() } }) }
    }
    .fullScreenCover(isPresented: $newSearch, onDismiss: { Task { await load() } }) {
      NavigationStack { SearchFlow(search: search, onSaved: { Task { await load() } }) }
    }
  }

  // MARK: Signed in

  private func signedIn(_ user: Member) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("You").font(.largeTitle.weight(.heavy)).accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("you-heading").padding(.top, 4)
        profile(user)
        if !error.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text(error).font(.subheadline)
            Button("Try again") { Task { await load() } }.buttonStyle(.quadSecondary)
          }
        }
        section("What you're looking for") { looking }
        section("Your places") { places }
        if !drafts.isEmpty { section("Not finished") { unfinished } }
        section("Account") { settings(user) }
        Button("Log out") { Task { await state.logout() } }
          .buttonStyle(QuadSecondaryButtonStyle(wide: true))
      }
      .padding(.horizontal, 16).padding(.bottom, 16)
    }
    .refreshable { await load() }
  }

  private func profile(_ user: Member) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 14) {
        if let avatar = user.avatar, !avatar.isEmpty {
          RemoteImage(path: avatar).frame(width: 64, height: 64).clipShape(Circle())
            .accessibilityHidden(true)
        } else {
          QuadAvatar(name: user.name, id: user.id, size: 64)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(user.name).font(.title3.weight(.heavy))
          Text(user.email).font(.footnote).foregroundStyle(Color.quadMuted).lineLimit(1)
          QuadChip(
            text: user.identity == "verified" ? "ID checked" : "ID not checked",
            symbol: user.identity == "verified" ? "checkmark.shield.fill" : "shield",
            kind: user.identity == "verified" ? .good : .plain)
        }
        Spacer(minLength: 0)
      }
      VStack(spacing: 8) {
        NavigationLink("Edit profile & checks") { ProfileEditor() }
          .buttonStyle(QuadSecondaryButtonStyle(wide: true, fill: .quadWell))
        NavigationLink("See your public profile") { MemberView(id: user.id) }
          .buttonStyle(QuadSecondaryButtonStyle(wide: true, fill: .quadWell))
      }
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading).quadCard(radius: 24)
  }

  @ViewBuilder private var looking: some View {
    if let search {
      NavigationLink {
        LookingView()
      } label: {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 5) {
            Text("What you're looking for").font(.subheadline.weight(.heavy))
            QuadChip(
              text: search.status == "active" ? "Search on" : "Search off",
              kind: search.status == "active" ? .good : .plain)
          }
          Spacer(minLength: 0)
          chevron
        }
        .padding(16).quadCard(radius: 22).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    } else if loaded {
      VStack(alignment: .leading, spacing: 10) {
        Text("Tell us your dates and budget and places that fit line up under Matches.")
          .font(.subheadline).foregroundStyle(Color.quadMuted)
        Button("Say what I'm looking for") { newSearch = true }.buttonStyle(.quadSecondary)
      }
      .padding(16).frame(maxWidth: .infinity, alignment: .leading).quadCard(radius: 22)
    } else {
      loading
    }
  }

  /// Shown where an answer from the server will go, so the page does not look finished early.
  private var loading: some View {
    HStack(spacing: 10) {
      ProgressView()
      Text("Loading").font(.subheadline.weight(.semibold)).foregroundStyle(Color.quadMuted)
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading).quadCard(radius: 22)
    .accessibilityElement(children: .combine)
  }

  private var places: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !loaded { loading }
      ForEach(mine) { place in
        NavigationLink {
          ListingManageView(listing: place)
        } label: {
          HStack(spacing: 12) {
            RemoteImage(path: place.images.first).frame(width: 52, height: 52)
              .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
              Text(place.title).font(.subheadline.weight(.heavy)).lineLimit(1)
              QuadChip(
                text: Self.status(place.status), kind: place.status == "approved" ? .good : .note)
            }
            Spacer(minLength: 0)
            chevron
          }
          .padding(12).quadCard(radius: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      Button {
        listing = .new()
      } label: {
        Label("List your place", systemImage: "plus")
      }
      .buttonStyle(.quadSecondary)
    }
  }

  /// A place's status in words. The server calls a place nobody else can see yet "pending".
  static func status(_ status: String) -> String {
    switch status {
    case "approved": return "Published"
    case "pending": return "Not published"
    default: return ChatText.plain(status)
    }
  }

  private var unfinished: some View {
    card {
      let places = drafts.filter { $0.kind == "listing" }
      ForEach(Array(places.enumerated()), id: \.element.id) { index, draft in
        if index > 0 { divider }
        Button {
          listing = ListingFlowStart(id: draft.id, resumesDraft: true)
        } label: {
          rowLabel("Resume place · \(draft.id.prefix(8))", "house")
        }
        .buttonStyle(.plain)
      }
      if drafts.contains(where: { $0.kind == "search" }) {
        if !places.isEmpty { divider }
        Button {
          newSearch = true
        } label: {
          rowLabel("Resume what you're looking for", "magnifyingglass")
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func settings(_ user: Member) -> some View {
    card {
      link("Saved posts", "bookmark") { SavedView() }
      divider
      link("Blocked members", "hand.raised") { BlockedMembersView() }
      divider
      link("Change password", "key") { PasswordView() }
      divider
      link("Data & privacy", "lock") { PrivacyView() }
      #if DEBUG
        divider
        link("Device capture check", "camera.viewfinder") { DeviceCaptureCheckView() }
      #endif
      divider
      Link(destination: state.api.baseURL) { rowLabel("Open public website", "safari") }
      if user.role == "admin" {
        divider
        Link(destination: state.api.url("/#account")) {
          rowLabel("Staff review workspace (web)", "checklist")
        }
      }
      divider
      link("Delete account", "trash") { AccountDeletionView() }
      if state.deletionReceipt != nil {
        divider
        link("Account deletion status", "clock") { DeletionStatusView() }
      }
    }
  }

  // MARK: Guest

  private var guest: some View {
    ScrollView {
      VStack(spacing: 18) {
        VStack(spacing: 12) {
          QuadLogo(size: 56)
          Text("Make your next move").font(.title2.weight(.heavy))
          Text("Post a place, find a match, and keep your conversations together.")
            .font(.subheadline).foregroundStyle(Color.quadMuted).multilineTextAlignment(.center)
          Button("Log in or create an account") { state.showLogin = true }
            .buttonStyle(.quadPrimaryWide)
        }
        .padding(.top, 40).padding(.horizontal, 8)
        card {
          link("Data & privacy", "lock") { PrivacyView() }
          #if DEBUG
            divider
            link("Device capture check", "camera.viewfinder") { DeviceCaptureCheckView() }
          #endif
          if state.deletionReceipt != nil {
            divider
            link("Account deletion status", "clock") { DeletionStatusView() }
          }
        }
      }
      .padding(.horizontal, 16).padding(.bottom, 16)
    }
  }

  // MARK: Pieces

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline.weight(.heavy)).accessibilityAddTraits(.isHeader)
      content()
    }
  }

  private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(spacing: 0) { content() }.quadCard(radius: 22)
  }

  private func link<Destination: View>(
    _ title: String, _ symbol: String, @ViewBuilder to destination: () -> Destination
  ) -> some View {
    NavigationLink {
      destination()
    } label: {
      rowLabel(title, symbol)
    }
    .buttonStyle(.plain)
  }

  private func rowLabel(_ title: String, _ symbol: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Color.quadMuted)
        .frame(width: 26).accessibilityHidden(true)
      Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.quadInk)
      Spacer(minLength: 0)
      chevron
    }
    .padding(.horizontal, 16).padding(.vertical, 14).contentShape(Rectangle())
  }

  private var chevron: some View {
    Image(systemName: "chevron.right").font(.footnote.weight(.bold))
      .foregroundStyle(Color.quadMuted).accessibilityHidden(true)
  }

  private var divider: some View { Divider().padding(.leading, 54) }

  func load() async {
    guard state.user != nil else { return }
    do {
      // Asked for together, so a slow connection is waited on once and the page fills in whole.
      async let places: ListingsResponse = state.api.get("/api/mine")
      async let own: MySearchResponse = state.api.get("/api/my-search")
      async let unfinished: DraftsResponse = state.api.get("/api/drafts")
      let (l, s, d) = try await (places, own, unfinished)
      mine = l.listings
      search = s.search
      drafts = d.drafts
      error = ""
    } catch { self.error = error.localizedDescription }
    loaded = true
  }
}

/// Editing your own profile, and sending the document for your ID check.
struct ProfileEditor: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var bio = ""
  @State private var phone = ""
  @State private var instagram = ""
  @State private var website = ""
  @State private var preservedSocials: [String: String] = [:]
  /// What staff wrote about the ID check, if anything.
  @State private var identityNote = ""
  @State private var notice = ""
  @State private var error = ""
  @State private var busy = false
  @State private var loaded = false
  @State private var picking = false
  @State private var uploadKind = "identity"
  @State private var avatar: String?
  @State private var photos: [String] = []
  @State private var removing: String?

  private var checked: Bool { state.user?.identity == "verified" }

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
          Text("Profile and checks").font(.title2.weight(.heavy))
            .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, 4)
        if loaded {
          photo
          details
          gallery
          identity
        } else if error.isEmpty {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }
        if !error.isEmpty { Text(error).font(.subheadline).foregroundStyle(Color(quad: 0xB42318)) }
      }
      .padding(.horizontal, 16).padding(.bottom, 16)
    }
    // A form with its own Save button: the tab bar steps aside, and the room it reserves goes.
    .contentMargins(.bottom, 0, for: .scrollContent)
    .hidesQuadTabBar()
    .scrollDismissesKeyboard(.interactively)
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
    .task { await load() }
    .confirmationDialog(
      "Remove this public photo?",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    ) {
      Button("Remove photo", role: .destructive) {
        guard let photo = removing else { return }
        removing = nil
        run {
          try await state.api.act("/api/profile/media/remove", ["url": photo])
          try await reloadPhotos()
          await state.refreshSession()
        }
      }
      Button("Cancel", role: .cancel) { removing = nil }
    }
    .fileImporter(
      isPresented: $picking,
      allowedContentTypes: uploadKind == "identity" ? [.pdf, .jpeg, .png] : [.jpeg, .png]
    ) { result in
      run {
        try await state.api.upload(
          uploadKind == "identity" ? "/api/profile/identity" : "/api/profile/media",
          file: result.get(), fields: uploadKind == "identity" ? [:] : ["kind": uploadKind])
        try await reloadPhotos()
        notice = "Upload saved"
        await state.refreshSession()
      }
    }
  }

  // MARK: Parts

  private var photo: some View {
    HStack(spacing: 14) {
      if let avatar {
        RemoteImage(path: avatar).frame(width: 84, height: 84).clipShape(Circle())
          .accessibilityLabel("Your profile photo")
      } else {
        QuadAvatar(name: name, id: state.user?.id ?? name, size: 84)
      }
      VStack(alignment: .leading, spacing: 8) {
        Button(avatar == nil ? "Upload profile photo" : "Change profile photo") {
          uploadKind = "avatar"
          picking = true
        }
        .buttonStyle(.quadSecondary)
        if let avatar {
          Button("Remove profile photo") { removing = avatar }
            .font(.subheadline.weight(.bold)).foregroundStyle(Color.quadLink)
        }
      }
      .disabled(busy)
      Spacer(minLength: 0)
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading).quadCard(radius: 24)
  }

  @ViewBuilder private var details: some View {
    field("Name") { TextField("Your name", text: $name).textContentType(.name) }
    Text("Changing your name resets your ID check.").font(.footnote)
      .foregroundStyle(Color.quadMuted)
    field("Phone (only you and staff see it)") {
      TextField("Phone", text: $phone).keyboardType(.phonePad)
    }
    field("About you (public)") {
      TextField("A few lines people read on your profile", text: $bio, axis: .vertical)
        .lineLimit(3...8).accessibilityIdentifier("profile-bio")
    }
    field("Instagram link") {
      TextField("https://", text: $instagram).textInputAutocapitalization(.never)
        .autocorrectionDisabled().keyboardType(.URL)
    }
    field("Website link") {
      TextField("https://", text: $website).textInputAutocapitalization(.never)
        .autocorrectionDisabled().keyboardType(.URL)
    }
    if !notice.isEmpty {
      Text(notice).font(.subheadline.weight(.bold)).foregroundStyle(Color.quadGreenText)
    }
    Button("Save profile") {
      run {
        let _: EmptyResponse = try await state.api.post(
          "/api/profile",
          [
            "name": name, "phone": phone, "bio": bio,
            "socials": preservedSocials.merging(["instagram": instagram, "website": website]) {
              _, new in new
            }.filter { !$0.value.isEmpty },
          ])
        await state.refreshSession()
        notice = "Profile saved"
      }
    }
    .buttonStyle(.quadPrimaryWide).disabled(busy)
  }

  private var gallery: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Photos on your profile").font(.headline.weight(.heavy))
        .accessibilityAddTraits(.isHeader)
      if !photos.isEmpty {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
          ForEach(photos, id: \.self) { picture in
            RemoteImage(path: picture).frame(height: 140).frame(maxWidth: .infinity)
              .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
              .overlay(alignment: .topTrailing) {
                Button {
                  removing = picture
                } label: {
                  Image(systemName: "xmark").font(.caption.weight(.heavy))
                    .foregroundStyle(.white).frame(width: 30, height: 30)
                    .background(Color.quadInk.opacity(0.75), in: Circle())
                }
                .padding(6).accessibilityLabel("Remove gallery photo")
              }
          }
        }
      }
      Button("Add public gallery photo") {
        uploadKind = "photo"
        picking = true
      }
      .buttonStyle(.quadSecondary)
    }
    .disabled(busy)
  }

  private var identity: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Text("ID check").font(.headline.weight(.heavy)).accessibilityAddTraits(.isHeader)
        QuadChip(
          text: checked ? "ID checked" : "ID not checked",
          symbol: checked ? "checkmark.shield.fill" : "shield", kind: checked ? .good : .plain)
      }
      if !identityNote.isEmpty { Text(identityNote).font(.subheadline) }
      Text(
        "Your ID document is seen only by you and staff. Sending one does not mean it is checked; staff review it first."
      )
      .font(.footnote).foregroundStyle(Color.quadMuted)
      Button("Submit private identity document") {
        uploadKind = "identity"
        picking = true
      }
      .buttonStyle(.quadSecondary).disabled(busy)
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading).quadCard(radius: 24)
  }

  private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption.weight(.bold)).foregroundStyle(Color.quadMuted)
      content().modifier(QuadFieldBox())
    }
  }

  // MARK: Doing things

  private func load() async {
    do {
      let r: AccountResponse = try await state.api.get("/api/profile")
      name = r.user.name
      phone = r.profile.phone
      bio = r.profile.bio
      preservedSocials = r.profile.socials
      instagram = r.profile.socials["instagram"] ?? ""
      website = r.profile.socials["website"] ?? ""
      identityNote = r.identityNote ?? ""
      avatar = r.profile.avatar
      photos = r.profile.photos
      loaded = true
    } catch { self.error = error.localizedDescription }
  }

  /// Runs one change, showing what went wrong if it fails.
  private func run(_ work: @escaping () async throws -> Void) {
    Task {
      busy = true
      defer { busy = false }
      do {
        notice = ""
        try await work()
        error = ""
      } catch { self.error = error.localizedDescription }
    }
  }

  func reloadPhotos() async throws {
    let account: AccountResponse = try await state.api.get("/api/profile")
    avatar = account.profile.avatar
    photos = account.profile.photos
  }
}
struct PasswordView: View {
  @EnvironmentObject var state: AppState
  @State private var current = ""
  @State private var next = ""
  @State private var message = ""
  @State private var busy = false
  var body: some View {
    Form {
      SecureField("Current password", text: $current).textContentType(.password)
      SecureField("New password (15–128 characters)", text: $next).textContentType(.newPassword)
      Button("Change password") {
        Task {
          busy = true
          defer { busy = false }
          do {
            try await state.api.act(
              "/api/auth/password", ["currentPassword": current, "newPassword": next])
            current = ""
            next = ""
            message = "Password changed. Other password sessions were signed out."
          } catch { message = error.localizedDescription }
        }
      }.disabled(busy)
      Text(message)
    }.navigationTitle("Password")
  }
}
struct SavedView: View {
  @EnvironmentObject var state: AppState
  @State private var listings: [Listing] = []
  @State private var searches: [HousingSearch] = []
  @State private var unavailable = 0
  @State private var cursor: String?
  @State private var error = ""
  @State private var loading = false
  @State private var loaded = false
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 12) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "chevron.left")
          }
          .buttonStyle(.quadIcon).accessibilityLabel("Back")
          Text("Saved posts").font(.title2.weight(.heavy)).accessibilityAddTraits(.isHeader)
        }
        .padding(.top, 4)
        ForEach(listings.filter { !state.hiddenMemberIDs.contains($0.ownerId) }) { l in
          QuadListingCard(listing: l)
        }
        ForEach(searches.filter { !state.hiddenMemberIDs.contains($0.ownerId) }) { s in
          QuadSearchCard(search: s)
        }
        if unavailable > 0 {
          Text("\(unavailable) saved posts are no longer available.").font(.footnote)
            .foregroundStyle(Color.quadMuted)
        }
        if cursor != nil {
          Button("Load more") { Task { await load(more: true) } }
            .buttonStyle(QuadSecondaryButtonStyle(wide: true)).disabled(loading)
        }
        if !error.isEmpty { Text(error).font(.subheadline) }
        if loaded && listings.isEmpty && searches.isEmpty && unavailable == 0 && error.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("Nothing saved yet").font(.headline.weight(.heavy))
            Text("Save a place or a person from their post, or from Matches, and it is kept here. Only you can see what you save.")
              .font(.subheadline).foregroundStyle(Color.quadMuted)
          }
          .padding(16).frame(maxWidth: .infinity, alignment: .leading).quadCard(radius: 22)
        }
      }
      .padding(.horizontal, 16).padding(.bottom, 16)
    }
    .foregroundStyle(Color.quadInk)
    .background(Color.quadGround.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .task { await load() }
  }
  func load(more: Bool = false) async {
    guard !loading else { return }
    loading = true
    defer {
      loading = false
      loaded = true
    }
    do {
      let page: SavedResponse = try await state.api.get(
        "/api/social/saved"
          + (more
            ? "?cursor=" + (cursor ?? "").addingPercentEncoding(
              withAllowedCharacters: .urlQueryAllowed)! : ""))
      var pageListings: [Listing] = []
      var pageSearches: [HousingSearch] = []
      var pageUnavailable = 0
      for item in page.items {
        if !item.available {
          pageUnavailable += 1
        } else {
          do {
            if item.targetType == "listing" {
              let result: ListingResponse = try await state.api.get(
                "/api/listings/\(item.targetId)")
              pageListings.append(result.listing)
            } else {
              let result: MySearchResponse = try await state.api.get(
                "/api/searches/\(item.targetId)")
              if let search = result.search { pageSearches.append(search) }
            }
          } catch {
            // A target may disappear between fetching the saved page and its details.
            if (error as? APIError)?.status == 404 { pageUnavailable += 1 } else { throw error }
          }
        }
      }
      listings = (more ? listings : []) + pageListings
      searches = (more ? searches : []) + pageSearches
      unavailable = (more ? unavailable : 0) + pageUnavailable
      cursor = page.nextCursor
      error = ""
    } catch { self.error = error.localizedDescription }
  }
}
