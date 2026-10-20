import SwiftUI

struct BlockedMember: Decodable, Identifiable {
  let id: String
  let name: String
}
struct BlockedMembersResponse: Decodable {
  let members: [BlockedMember]
  let hiddenMemberIDs: [String]
}
struct MemberSafetyActions: View {
  @EnvironmentObject var state: AppState
  let memberID: String
  @State private var busy = false
  @State private var error = ""
  @State private var notice = ""
  @State private var confirmBlock = false
  @State private var reporting = false
  @State private var reason = ""
  private var blocked: Bool { state.blockedMembers.contains { $0.id == memberID } }
  var body: some View {
    if memberID != state.user?.id {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Button(blocked ? "Unblock member" : "Block member", role: blocked ? nil : .destructive) {
            if state.requireLogin() { confirmBlock = true }
          }
          Button("Report member") { if state.requireLogin() { reporting = true } }
        }.disabled(busy)
        if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
        if !notice.isEmpty { Text(notice).font(.callout) }
      }.confirmationDialog(
        blocked ? "Unblock this member?" : "Block this member?", isPresented: $confirmBlock,
        titleVisibility: .visible
      ) {
        Button(blocked ? "Unblock" : "Block", role: blocked ? nil : .destructive) {
          Task { await changeBlock() }
        }
      } message: {
        Text(
          "Blocking hides their posts and comments while you are signed in and prevents new messages, documents and proposals between you. Existing reservation history remains available."
        )
      }
      .alert("Report member", isPresented: $reporting) {
        TextField("What happened?", text: $reason)
        Button("Send report") { Task { await report() } }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Explain the behavior so staff can review it. Reports are private.")
      }
    }
  }
  func changeBlock() async {
    busy = true
    defer { busy = false }
    do {
      try await state.api.act("/api/members/\(memberID)/\(blocked ? "unblock" : "block")")
      await state.refreshBlocks()
      error = ""
    } catch { self.error = error.localizedDescription }
  }
  func report() async {
    busy = true
    defer { busy = false }
    do {
      try await state.api.act("/api/members/\(memberID)/report", ["reason": reason])
      reason = ""
      error = ""
      notice = "Report sent for staff review."
    } catch { self.error = error.localizedDescription }
  }
}
struct BlockedMembersView: View {
  @EnvironmentObject var state: AppState
  var body: some View {
    List {
      if state.blockedMembers.isEmpty { Text("You have not blocked any members.") }
      ForEach(state.blockedMembers) { member in
        VStack(alignment: .leading) {
          Text(member.name).font(.headline)
          MemberSafetyActions(memberID: member.id)
        }
      }
    }.navigationTitle("Blocked members").task { await state.refreshBlocks() }.refreshable {
      await state.refreshBlocks()
    }
  }
}
extension AppState {
  func refreshBlocks() async {
    guard let owner = user?.id else { return }
    do {
      let result: BlockedMembersResponse = try await api.get("/api/blocked-members")
      guard user?.id == owner else { return }
      blockedMembers = result.members
      hiddenMemberIDs = Set(result.hiddenMemberIDs)
    } catch { self.error = error.localizedDescription }
  }
}
