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
  @State private var editing: String?
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
          .accessibilityLabel(s.liked ? "Unlike post" : "Like post").accessibilityValue(
            "\(s.likeCount) likes"
          ).frame(minHeight: 44)
          Text("\(s.commentCount) comments").font(.subheadline)
          Spacer()
          Button {
            perform {
              try await state.api.act(base + "/save", ["saved": !s.saved])
              await load()
            }
          } label: {
            Image(systemName: s.saved ? "bookmark.fill" : "bookmark")
          }.accessibilityLabel(s.saved ? "Unsave privately" : "Save privately").frame(
            minWidth: 44, minHeight: 44)
        }.disabled(busy)
      }
      ForEach(comments.filter { !state.hiddenMemberIDs.contains($0.authorId ?? "") }) { c in
        VStack(alignment: .leading, spacing: 4) {
          if let author = c.authorId {
            NavigationLink(c.authorName) { MemberView(id: author) }.font(.caption.bold())
          } else {
            Text(c.authorName).font(.caption.bold())
          }
          Text(c.body).font(.subheadline)
          if !c.unavailable {
            HStack {
              Button("Reply") {
                editing = nil
                draft = ""
                reply = c.id
              }
              if c.authorId == state.user?.id {
                Button("Edit") {
                  editing = c.id
                  draft = c.body
                  reply = nil
                }
                Button("Delete", role: .destructive) {
                  perform {
                    try await state.api.act("/api/social/comments/\(c.id)/delete")
                    if editing == c.id {
                      editing = nil
                      draft = ""
                    }
                    await load()
                  }
                }
              } else {
                Button("Report") { if state.requireLogin() { reportID = c.id } }
              }
            }.font(.body).disabled(busy)
          }
        }.padding(.leading, c.parentId == nil ? 0 : 18)
      }
      if cursor != nil {
        Button("More comments") { Task { await more() } }.disabled(loadingComments)
      }
      if reply != nil || editing != nil {
        HStack {
          Text(editing == nil ? "Replying to a comment" : "Editing your comment").font(.caption)
          Button("Cancel") {
            reply = nil
            editing = nil
            draft = ""
          }.disabled(busy)
        }
      }
      HStack {
        TextField("Add a public comment", text: $draft, axis: .vertical).textFieldStyle(
          .roundedBorder
        ).accessibilityIdentifier("comment-draft").disabled(busy)
        Button(editing == nil ? "Post" : "Save comment") {
          perform {
            if let editing {
              try await state.api.act("/api/social/comments/\(editing)/edit", ["body": draft])
            } else {
              try await state.api.act(
                base + "/comments",
                ["body": draft, "clientId": clientID, "parentId": reply as Any? ?? NSNull()])
            }
            editing = nil
            draft = ""
            reply = nil
            clientID = UUID().uuidString
            await load()
          }
        }.disabled(
          busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.count > 1500)
      }
      if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
    }.task(id: state.user?.id) {
      draft = ""
      reply = nil
      editing = nil
      await load()
    }
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") {
          UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil)
        }.accessibilityIdentifier("dismiss-keyboard")
      }
    }
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
