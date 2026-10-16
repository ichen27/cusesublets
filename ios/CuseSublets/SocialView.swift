import SwiftUI

struct SocialView: View {
  @EnvironmentObject var state: AppState
  let type: String
  let targetID: String
  @State private var summary: SocialSummary?
  @State private var comments: [SocialComment] = []
  @State private var cursor: String?
  @State private var draft = ""
  @State private var reply: String?
  @State private var clientID = UUID().uuidString
  @State private var error = ""
  @State private var busy = false
  @State private var loadingComments = false
  @State private var reportID: String?
  @State private var reportReason = ""
  var base: String { "/api/social/\(type)/\(targetID)" }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let s = summary {
        HStack {
          Button {
            perform {
              try await state.api.act(base + "/like", ["liked": !s.liked])
              await load()
            }
          } label: {
            Label("\(s.likeCount)", systemImage: s.liked ? "heart.fill" : "heart")
          }
          Text("\(s.commentCount) comments").font(.subheadline)
          Spacer()
          Button {
            perform {
              try await state.api.act(base + "/save", ["saved": !s.saved])
              await load()
            }
          } label: {
            Image(systemName: s.saved ? "bookmark.fill" : "bookmark")
          }.accessibilityLabel(s.saved ? "Unsave privately" : "Save privately")
        }.disabled(busy)
      }
      ForEach(comments) { c in
        VStack(alignment: .leading, spacing: 4) {
          Text(c.authorName).font(.caption.bold())
          Text(c.body).font(.subheadline)
          if !c.unavailable {
            HStack {
              Button("Reply") { reply = c.id }
              if c.authorId == state.user?.id {
                Button("Delete", role: .destructive) {
                  perform {
                    try await state.api.act("/api/social/comments/\(c.id)/delete")
                    await load()
                  }
                }
              } else {
                Button("Report") { if state.requireLogin() { reportID = c.id } }
              }
            }.font(.caption)
          }
        }.padding(.leading, c.parentId == nil ? 0 : 18)
      }
      if cursor != nil {
        Button("More comments") { Task { await more() } }.disabled(loadingComments)
      }
      if reply != nil {
        HStack {
          Text("Replying to a comment").font(.caption)
          Button("Cancel") { reply = nil }
        }
      }
      HStack {
        TextField("Add a public comment", text: $draft, axis: .vertical).textFieldStyle(
          .roundedBorder)
        Button("Post") {
          perform {
            try await state.api.act(
              base + "/comments",
              ["body": draft, "clientId": clientID, "parentId": reply as Any? ?? NSNull()])
            draft = ""
            reply = nil
            clientID = UUID().uuidString
            await load()
          }
        }.disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
    }.task(id: state.user?.id) { await load() }
      .onChange(of: draft) { _, _ in if !busy { clientID = UUID().uuidString } }
      .onChange(of: reply) { _, _ in if !busy { clientID = UUID().uuidString } }
      .alert(
        "Report comment",
        isPresented: Binding(get: { reportID != nil }, set: { if !$0 { reportID = nil } })
      ) {
        TextField("Reason", text: $reportReason)
        Button("Report", role: .destructive) {
          let id = reportID
          perform {
            if let id {
              try await state.api.act("/api/social/comments/\(id)/report", ["reason": reportReason])
              reportID = nil
              reportReason = ""
            }
          }
        }
        Button("Cancel", role: .cancel) { reportID = nil }
      }
  }
  func perform(_ operation: @escaping () async throws -> Void) {
    guard state.requireLogin() else { return }
    Task {
      busy = true
      defer { busy = false }
      do {
        try await operation()
        error = ""
      } catch { self.error = error.localizedDescription }
    }
  }
  func load() async {
    do {
      summary = try await state.api.get(base)
      let page: CommentsPage = try await state.api.get(base + "/comments")
      comments = page.comments
      cursor = page.nextCursor
      error = ""
    } catch { self.error = error.localizedDescription }
  }
  func more() async {
    guard let cursor, !loadingComments else { return }
    loadingComments = true
    defer { loadingComments = false }
    do {
      let page: CommentsPage = try await state.api.get(
        base + "/comments?cursor=" + cursor.addingPercentEncoding(
          withAllowedCharacters: .urlQueryAllowed)!)
      comments += page.comments.filter { next in !comments.contains(where: { $0.id == next.id }) }
      self.cursor = page.nextCursor
    } catch { self.error = error.localizedDescription }
  }
}
struct MatchesView: View {
  @EnvironmentObject var state: AppState
  @State private var mine: [Listing] = []
  @State private var search: HousingSearch?
  @State private var selection = ""
  @State private var matches: [MatchItem] = []
  @State private var error = ""
  @State private var loading = false
  var body: some View {
    Group {
      if state.user == nil {
        VStack {
          EmptyState(
            title: "Find your fit",
            text: "Sign in and add a place or housing search to see matches.")
          Button("Log in") { state.showLogin = true }.buttonStyle(.borderedProminent)
        }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Picker("Match for", selection: $selection) {
              Text("Choose an activity").tag("")
              if let search, search.status == "active" {
                Text("My housing search").tag("search:" + search.id)
              }
              ForEach(mine.filter { $0.status == "approved" }) {
                Text($0.title).tag("listing:" + $0.id)
              }
            }
            if loading { ProgressView() }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            ForEach(matches) { m in
              VStack(alignment: .leading, spacing: 10) {
                if let l = m.listing {
                  NavigationLink {
                    ListingView(listing: l)
                  } label: {
                    ListingCard(listing: l)
                  }.buttonStyle(.plain)
                }
                if let s = m.search {
                  NavigationLink {
                    SearchDetailView(search: s)
                  } label: {
                    SearchCard(search: s)
                  }.buttonStyle(.plain)
                  Button("Start a conversation") {
                    Task {
                      await state.contact(listingID: String(selection.dropFirst(8)), searchID: s.id)
                    }
                  }
                }
                Text(m.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
              }
            }
            if matches.isEmpty && !loading && error.isEmpty {
              EmptyState(
                title: "Matches start with your plans",
                text:
                  "Publish a place or turn on your housing search in You. Matches must cover dates, budget, area and required conditions."
              )
            }
          }.padding()
        }
      }
    }.navigationTitle("Matches").task { await loadSources() }.task(id: selection) {
      await loadMatches()
    }.refreshable {
      await loadSources()
      await loadMatches()
    }
  }
  func loadSources() async {
    guard state.user != nil else { return }
    do {
      let l: ListingsResponse = try await state.api.get("/api/mine")
      mine = l.listings
      let s: MySearchResponse = try await state.api.get("/api/my-search")
      search = s.search
      if selection.isEmpty {
        if let search, search.status == "active" {
          selection = "search:" + search.id
        } else if let l = mine.first(where: { $0.status == "approved" }) {
          selection = "listing:" + l.id
        }
      }
    } catch { self.error = error.localizedDescription }
  }
  func loadMatches() async {
    matches = []
    guard !selection.isEmpty else { return }
    loading = true
    defer { loading = false }
    do {
      let p = selection.split(separator: ":", maxSplits: 1)
      guard p.count == 2 else { return }
      let r: MatchesResponse = try await state.api.get(
        "/api/matches?sourceType=\(p[0])&sourceId=\(p[1])")
      try Task.checkCancellation()
      matches = r.matches
      error = ""
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }
}
