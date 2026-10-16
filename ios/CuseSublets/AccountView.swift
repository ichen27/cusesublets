import SwiftUI
import UniformTypeIdentifiers

struct AccountView: View {
  @EnvironmentObject var state: AppState
  @State private var mine: [Listing] = []
  @State private var search: HousingSearch?
  @State private var newListing = false
  @State private var newSearch = false
  @State private var error = ""
  @State private var drafts: [DraftRecord] = []
  var body: some View {
    Group {
      if let user = state.user {
        List {
          Section {
            Text(user.name).font(.title.bold())
            Text(user.email).foregroundStyle(.secondary)
            NavigationLink("Edit profile & checks") { ProfileEditor() }
            NavigationLink("Saved posts") { SavedView() }
            NavigationLink("Change password") { PasswordView() }
          }
          Section("Your housing search") {
            if let search {
              SearchCard(search: search)
              Button(search.status == "active" ? "Turn search off" : "Turn search on") {
                Task {
                  do {
                    try await state.api.act(
                      "/api/my-search/status",
                      ["status": search.status == "active" ? "paused" : "active"])
                    await load()
                  } catch { self.error = error.localizedDescription }
                }
              }.disabled(search.status == "removed")
            }
            Button(search == nil ? "Create housing search" : "Edit search") { newSearch = true }
          }
          Section("Your places") {
            Button("List your place", systemImage: "plus") { newListing = true }
            ForEach(mine) { l in
              NavigationLink {
                ListingManageView(listing: l)
              } label: {
                VStack(alignment: .leading) {
                  Text(l.title)
                  StatusText(text: l.status == "approved" ? "Published" : l.status)
                }
              }
            }
          }
          Section("Private drafts") {
            ForEach(drafts.filter { $0.kind == "listing" }) { d in
              NavigationLink("Resume place · \(d.id.prefix(8))") {
                ListingEditor(draftID: d.id, onSaved: { Task { await load() } })
              }
            }
            if drafts.contains(where: { $0.kind == "search" }) {
              Button("Resume housing search") { newSearch = true }
            }
          }
          Section {
            Link("Open public website", destination: state.api.baseURL)
            if user.role == "admin" {
              Link("Staff review workspace (web)", destination: state.api.url("/#account"))
            }
            Button("Log out", role: .destructive) { Task { await state.logout() } }
          }
          if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }
      } else {
        VStack(spacing: 20) {
          EmptyState(
            title: "Make your next move",
            text: "Post a place, find a match, and keep your conversations together.")
          Button("Log in or create an account") { state.showLogin = true }.buttonStyle(
            .borderedProminent)
        }
      }
    }.navigationTitle("You")
      .task(id: state.user?.id) { await load() }.refreshable { await load() }
      .sheet(isPresented: $newListing) {
        NavigationStack { ListingEditor(onSaved: { Task { await load() } }) }
      }
      .sheet(isPresented: $newSearch) {
        NavigationStack { SearchEditor(search: search, onSaved: { Task { await load() } }) }
      }
  }
  func load() async {
    guard state.user != nil else { return }
    do {
      let l: ListingsResponse = try await state.api.get("/api/mine")
      mine = l.listings
      let s: MySearchResponse = try await state.api.get("/api/my-search")
      search = s.search
      let d: DraftsResponse = try await state.api.get("/api/drafts")
      drafts = d.drafts
      error = ""
    } catch { self.error = error.localizedDescription }
  }
}
struct ProfileEditor: View {
  @EnvironmentObject var state: AppState
  @State private var name = ""
  @State private var bio = ""
  @State private var phone = ""
  @State private var instagram = ""
  @State private var website = ""
  @State private var preservedSocials: [String: String] = [:]
  @State private var note = ""
  @State private var error = ""
  @State private var busy = false
  @State private var loaded = false
  @State private var picking = false
  @State private var uploadKind = "identity"
  var body: some View {
    Form {
      Section("Profile") {
        TextField("Name", text: $name)
        TextField("Phone (private)", text: $phone).keyboardType(.phonePad)
        TextField("Bio (public)", text: $bio, axis: .vertical)
        TextField("Instagram HTTPS URL", text: $instagram).textInputAutocapitalization(.never)
        TextField("Website HTTPS URL", text: $website).textInputAutocapitalization(.never)
        Text("Changing your name resets identity review.").font(.caption)
        Button("Save profile") {
          Task {
            busy = true
            defer { busy = false }
            do {
              let _: EmptyResponse = try await state.api.post(
                "/api/profile",
                [
                  "name": name, "phone": phone, "bio": bio,
                  "socials": preservedSocials.merging(["instagram": instagram, "website": website])
                  { _, new in new }.filter {
                    !$0.value.isEmpty
                  },
                ])
              await state.refreshSession()
              note = "Profile saved"
              error = ""
            } catch { self.error = error.localizedDescription }
          }
        }.disabled(busy || !loaded)
      }
      Section("Photos and private identity check") {
        Button("Upload profile photo") {
          uploadKind = "avatar"
          picking = true
        }
        Button("Add public gallery photo") {
          uploadKind = "photo"
          picking = true
        }
        Button("Submit private identity document") {
          uploadKind = "identity"
          picking = true
        }
        Text(
          "Identity documents are private to you and staff. Uploading a document does not grant verification."
        ).font(.caption)
        if !note.isEmpty { Text(note) }
      }
      if !error.isEmpty { Text(error).foregroundStyle(.red) }
    }.navigationTitle("Profile & checks").task {
      do {
        let r: AccountResponse = try await state.api.get("/api/profile")
        name = r.user.name
        phone = r.profile.phone
        bio = r.profile.bio
        preservedSocials = r.profile.socials
        instagram = r.profile.socials["instagram"] ?? ""
        website = r.profile.socials["website"] ?? ""
        note = r.identityNote ?? ""
        loaded = true
      } catch { self.error = error.localizedDescription }
    }
    .fileImporter(
      isPresented: $picking,
      allowedContentTypes: uploadKind == "identity" ? [.pdf, .jpeg, .png] : [.jpeg, .png]
    ) { result in
      Task {
        do {
          try await state.api.upload(
            uploadKind == "identity" ? "/api/profile/identity" : "/api/profile/media",
            file: result.get(), fields: uploadKind == "identity" ? [:] : ["kind": uploadKind])
          note = "Upload saved"
          await state.refreshSession()
        } catch { self.error = error.localizedDescription }
      }
    }
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
  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        ForEach(listings) { l in
          NavigationLink {
            ListingView(listing: l)
          } label: {
            ListingCard(listing: l)
          }.buttonStyle(.plain)
        }
        ForEach(searches) { s in
          NavigationLink {
            SearchDetailView(search: s)
          } label: {
            SearchCard(search: s)
          }.buttonStyle(.plain)
        }
        if unavailable > 0 { Text("\(unavailable) saved posts are no longer available.") }
        if cursor != nil {
          Button("Load more") { Task { await load(more: true) } }.disabled(loading)
        }
        if !error.isEmpty { Text(error).foregroundStyle(.red) }
        if listings.isEmpty && searches.isEmpty && unavailable == 0 {
          EmptyState(
            title: "Your private shortlist", text: "Save places and people from their posts.")
        }
      }.padding()
    }.navigationTitle("Saved").task { await load() }
  }
  func load(more: Bool = false) async {
    guard !loading else { return }
    loading = true
    defer { loading = false }
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
