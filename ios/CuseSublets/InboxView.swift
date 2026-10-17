import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct InboxView: View {
  @EnvironmentObject var state: AppState
  @State private var threads: [Conversation] = []
  @State private var error = ""
  @State private var loading = false
  var body: some View {
    Group {
      if state.user == nil {
        VStack {
          EmptyState(
            title: "Your conversations",
            text: "Discuss a place, share documents and negotiate dates in one thread.")
          Button("Log in") { state.showLogin = true }.buttonStyle(.borderedProminent)
        }
      } else {
        List {
          if !error.isEmpty { Text(error).foregroundStyle(.red) }
          if loading { ProgressView() }
          ForEach(threads) { c in
            NavigationLink {
              ConversationView(id: c.id)
            } label: {
              HStack {
                RemoteImage(path: c.listingImage).frame(width: 58, height: 58).clipShape(
                  RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                  Text(c.peerName).font(.headline)
                  Text(c.listingTitle).font(.caption).foregroundStyle(.secondary)
                  Text(c.lastMessage ?? "Start your conversation").lineLimit(2)
                }
              }
            }
          }
          if threads.isEmpty && !loading {
            Text("No conversations yet. Open a place or a match to contact someone.")
              .foregroundStyle(.secondary)
          }
        }
      }
    }.navigationTitle("Inbox").task { await load() }.refreshable { await load() }
      .navigationDestination(
        isPresented: Binding(
          get: { state.conversationID != nil }, set: { if !$0 { state.conversationID = nil } })
      ) { if let id = state.conversationID { ConversationView(id: id) } }
  }
  func load() async {
    guard state.user != nil else { return }
    loading = true
    defer { loading = false }
    do {
      let r: ConversationsResponse = try await state.api.get("/api/conversations")
      threads = r.conversations
      error = ""
    } catch { self.error = error.localizedDescription }
  }
}
struct ConversationView: View {
  @EnvironmentObject var state: AppState
  let id: String
  @State private var detail: ConversationDetail?
  @State private var message = ""
  @State private var error = ""
  @State private var busy = false
  @State private var showOffer = false
  @State private var picking = false
  @State private var preview: URL?
  @State private var dispute: Booking?
  @State private var reason = ""
  @State private var counter: Offer?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let d = detail {
          NavigationLink {
            MemberView(id: d.peer.id)
          } label: {
            Label(d.peer.name, systemImage: "person.crop.circle").font(.headline)
          }
          NavigationLink {
            ListingView(listing: d.listing)
          } label: {
            Label(d.listing.title, systemImage: "house").font(.headline)
          }
          ForEach(d.messages) { m in
            HStack {
              if m.senderId == state.user?.id { Spacer(minLength: 30) }
              Text(m.body).padding(12).background(
                m.senderId == state.user?.id ? Color.cuseCream : Color.gray.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 14))
              if m.senderId != state.user?.id { Spacer(minLength: 30) }
            }
          }
          ForEach(d.events) { e in Text(e.body).font(.caption).foregroundStyle(.secondary) }
          ForEach(d.offers) { o in
            VStack(alignment: .leading, spacing: 8) {
              Text("\(o.kind.capitalized): \(dollars(o.amount))/month").bold()
              Text("\(o.startDate) – \(o.endDate)")
              StatusText(text: o.status)
              if o.status == "pending" {
                if o.proposedBy == state.user?.id {
                  Button("Withdraw") { act("/api/offers/\(o.id)/withdraw") }
                } else {
                  HStack {
                    Button("Accept") { act("/api/offers/\(o.id)/accept") }
                    Button("Decline") { act("/api/offers/\(o.id)/decline") }
                    Button("Counter") {
                      counter = o
                      showOffer = true
                    }
                  }
                }
              }
            }.padding().frame(maxWidth: .infinity, alignment: .leading).background(
              Color.cuseCream, in: RoundedRectangle(cornerRadius: 12))
          }
          ForEach(d.bookings) { b in
            VStack(alignment: .leading, spacing: 8) {
              Text("Reservation · \(dollars(b.amount))/month").font(.headline)
              Text("\(b.startDate) – \(b.endDate)")
              Text("\(b.status) · Payment: \(b.paymentStatus)")
              if b.disputeStatus != "none" {
                Text("Issue: \(b.disputeStatus) · \(b.disputeReason ?? "")")
              }
              Text("Legal signing and live payments are not available yet.").font(.caption)
                .foregroundStyle(.secondary)
              if b.buyerId == state.user?.id {
                Button("Confirm move-in") {
                  act("/api/bookings/\(b.id)/action", ["action": "confirm-move-in"])
                }
                Button("Report a move-in issue") { dispute = b }
              }
            }.padding().background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
          }
          ForEach(d.attachments) { a in
            Button {
              Task {
                do {
                  preview = try await state.api.download(
                    "/api/chat-documents/\(a.id)", name: a.name)
                } catch { self.error = error.localizedDescription }
              }
            } label: {
              Label(a.name, systemImage: "doc")
            }
          }
          HStack {
            TextField("Private message", text: $message, axis: .vertical).lineLimit(1...6)
              .textFieldStyle(.roundedBorder)
            Button("Send") { send() }.disabled(
              busy || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
          HStack {
            Button("Share document", systemImage: "paperclip") { picking = true }
            Spacer()
            Button("Propose dates / rent") {
              counter = nil
              showOffer = true
            }
          }.font(.subheadline)
          Text(
            "Shared documents are visible to both participants. Lease and identity evidence belong in your private checks uploads."
          ).font(.caption).foregroundStyle(.secondary)
        } else if error.isEmpty {
          ProgressView()
        }
        if !error.isEmpty {
          Text(error).foregroundStyle(.red)
          Button("Retry") { Task { await load() } }
        }
      }.padding()
    }.navigationTitle(detail?.conversation.peerName ?? "Conversation")
      .navigationBarTitleDisplayMode(.inline)
      .task(id: id) {
        await load()
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: .seconds(10))
            await load()
          } catch { break }
        }
      }
      .refreshable { await load() }.quickLookPreview($preview)
      .sheet(isPresented: $showOffer) {
        if let d = detail {
          OfferEditor(conversationID: id, listing: d.listing, counter: counter) {
            Task { await load() }
          }
        }
      }
      .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf, .jpeg, .png]) { result in
        Task {
          do {
            let file = try result.get()
            try await state.api.upload("/api/conversations/\(id)/documents", file: file)
            await load()
          } catch { self.error = error.localizedDescription }
        }
      }
      .alert(
        "Report move-in issue",
        isPresented: Binding(get: { dispute != nil }, set: { if !$0 { dispute = nil } })
      ) {
        TextField("Describe the issue", text: $reason)
        Button("Submit") {
          if let b = dispute {
            act("/api/bookings/\(b.id)/action", ["action": "dispute", "reason": reason])
            dispute = nil
          }
        }
        Button("Cancel", role: .cancel) { dispute = nil }
      }
  }
  func load() async {
    do {
      let r: ConversationDetail = try await state.api.get("/api/conversations/\(id)")
      try Task.checkCancellation()
      detail = r
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }
  func act(_ path: String, _ body: [String: Any] = [:]) {
    guard !busy else { return }
    Task {
      busy = true
      defer { busy = false }
      do {
        try await state.api.act(path, body)
        error = ""
        await load()
      } catch { self.error = error.localizedDescription }
    }
  }
  func send() {
    guard !busy else { return }
    let text = message
    Task {
      busy = true
      defer { busy = false }
      do {
        try await state.api.act("/api/conversations/\(id)/messages", ["body": text])
        message = ""
        error = ""
        await load()
      } catch { self.error = error.localizedDescription }
    }
  }
}
struct OfferEditor: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) var dismiss
  let conversationID: String
  let listing: Listing
  let counter: Offer?
  let onSaved: () -> Void
  @State private var amount = ""
  @State private var start = Date()
  @State private var end = Date()
  @State private var kind = "offer"
  @State private var error = ""
  @State private var busy = false
  var body: some View {
    NavigationStack {
      Form {
        Section("Monthly rent and stay") {
          TextField("Monthly rent", text: $amount).keyboardType(.decimalPad)
          DatePicker("Start", selection: $start, displayedComponents: .date)
          DatePicker("End", selection: $end, displayedComponents: .date)
          Picker("Proposal", selection: $kind) {
            Text("Offer").tag("offer")
            Text("Asking-price request").tag("request")
          }
        }
        Text(
          "An accepted offer reserves dates only when the listing passes the required checks. Payment and signing remain unavailable."
        ).font(.caption)
        if !error.isEmpty { Text(error).foregroundStyle(.red) }
        Button(counter == nil ? "Send proposal" : "Send counteroffer") {
          Task {
            busy = true
            defer { busy = false }
            do {
              guard let price = Double(amount), price > 0 else {
                throw APIError(message: "Enter a valid monthly rent")
              }
              var b: [String: Any] = [
                "amount": kind == "request" ? listing.price : price, "startDate": isoDay(start),
                "endDate": isoDay(end), "kind": kind,
              ]
              if let counter { b["parentOfferId"] = counter.id }
              try await state.api.act("/api/conversations/\(conversationID)/offers", b)
              onSaved()
              dismiss()
            } catch { self.error = error.localizedDescription }
          }
        }.disabled(busy)
      }.navigationTitle("Proposal").toolbar { Button("Cancel") { dismiss() } }.onAppear {
        amount = String(counter?.amount ?? listing.price)
        start = parseDay(counter?.startDate ?? listing.startDate)
        end = parseDay(counter?.endDate ?? listing.endDate)
      }
    }
  }
}
