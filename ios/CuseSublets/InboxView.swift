import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The Inbox tab: every conversation, the one that changed last on top.
struct InboxView: View {
  @EnvironmentObject var state: AppState
  @State private var threads: [Conversation] = []
  @State private var error = ""
  @State private var loaded = false

  var body: some View {
    Group {
      if state.checkingSavedSession {
        CheckingSessionView()
      } else if state.user == nil {
        guest
      } else {
        list
      }
    }
    .foregroundStyle(Color.quadInk)
    .background(Color.quadGround.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .task(id: state.user?.id) { await load() }
    .navigationDestination(
      isPresented: Binding(
        get: { state.conversationID != nil }, set: { if !$0 { state.conversationID = nil } })
    ) { if let id = state.conversationID { ConversationView(id: id) } }
  }

  private var guest: some View {
    VStack(spacing: 14) {
      Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 44, weight: .semibold))
        .foregroundStyle(Color.quadMuted).accessibilityHidden(true)
      Text("Your conversations").font(.title2.weight(.heavy))
      Text("Ask about a place, agree on dates and rent, and share documents in one thread.")
        .font(.subheadline).foregroundStyle(Color.quadMuted).multilineTextAlignment(.center)
      Button("Log in") { state.showLogin = true }.buttonStyle(.quadPrimaryWide)
    }
    .padding(.horizontal, 32).padding(.bottom, QuadTabBar.reservedHeight)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var list: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Inbox").font(.largeTitle.weight(.heavy)).accessibilityAddTraits(.isHeader)
          .padding(.top, 4)
        if !error.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text(error).font(.subheadline)
            Button("Try again") { Task { await load() } }.buttonStyle(.quadSecondary)
          }
        }
        if !loaded && error.isEmpty {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }
        ForEach(threads) { thread in
          NavigationLink {
            ConversationView(id: thread.id)
          } label: {
            row(thread)
          }
          .buttonStyle(.plain)
        }
        if loaded && threads.isEmpty && error.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("No conversations yet").font(.headline.weight(.heavy))
            Text("Message someone from a place or a match and the thread shows up here.")
              .font(.subheadline).foregroundStyle(Color.quadMuted)
          }
          .padding(16).frame(maxWidth: .infinity, alignment: .leading).quadCard(radius: 20)
        }
      }
      .padding(.horizontal, 16).padding(.bottom, 16)
    }
    .refreshable { await load() }
  }

  private func row(_ thread: Conversation) -> some View {
    let peerID = [thread.buyerId, thread.sellerId].compactMap { $0 }
      .first { $0 != state.user?.id } ?? thread.peerName
    let stamp = ChatText.stamp(thread.updatedAt)
    return HStack(alignment: .top, spacing: 12) {
      QuadAvatar(name: thread.peerName, id: peerID, size: 48)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          Text(thread.peerName).font(.headline.weight(.heavy)).lineLimit(1)
          if ChatText.identity(thread.peerIdentity)?.checked == true {
            Image(systemName: "checkmark.shield.fill").font(.caption)
              .foregroundStyle(Color.quadGreen).accessibilityLabel("ID checked")
          }
          Spacer(minLength: 8)
          if !stamp.isEmpty {
            Text(stamp).font(.caption.weight(.semibold)).foregroundStyle(Color.quadMuted)
          }
        }
        Text(thread.listingTitle).font(.caption.weight(.bold)).foregroundStyle(Color.quadMuted)
          .lineLimit(1)
        Text(ChatText.preview(thread.lastMessage)).font(.subheadline).lineLimit(2)
          .multilineTextAlignment(.leading)
      }
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading).quadCard(radius: 20)
    .contentShape(Rectangle())
  }

  func load() async {
    guard state.user != nil else { return }
    do {
      let r: ConversationsResponse = try await state.api.get("/api/conversations")
      threads = r.conversations
      error = ""
    } catch { self.error = error.localizedDescription }
    loaded = true
  }
}

/// One conversation, about one place: what was said, offered, shared and done, in the order it
/// happened, with the message box at the bottom.
struct ConversationView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) private var dismiss
  let id: String
  @State private var detail: ConversationDetail?
  @State private var message = ""
  @State private var error = ""
  @State private var busy = false
  @State private var showOffer = false
  @State private var sharing = false
  @State private var picking = false
  @State private var preview: URL?
  @State private var dispute: Booking?
  @State private var reason = ""
  @State private var counter: Offer?

  private var items: [ChatItem] {
    detail.map { ChatTimeline.items($0, viewerID: state.user?.id) } ?? []
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 10) {
          if let d = detail {
            ForEach(items) { item in row(item, d) }
          } else if error.isEmpty {
            ProgressView().padding(.top, 60)
          }
          if !error.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text(error).font(.subheadline)
              Button("Try again") { Task { await load() } }.buttonStyle(.quadSecondary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).quadCard(radius: 20)
          }
          Color.clear.frame(height: 1).id("end")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
      }
      // This screen has no tab bar under it, so it drops the room the tab reserves for one.
      .contentMargins(.bottom, 0, for: .scrollContent)
      .scrollDismissesKeyboard(.interactively)
      // The newest thing is what someone opens a conversation to see.
      .onChange(of: items.last?.id) { proxy.scrollTo("end", anchor: .bottom) }
    }
    .foregroundStyle(Color.quadInk)
    .background(Color.quadGround.ignoresSafeArea())
    .safeAreaInset(edge: .top, spacing: 0) { header }
    .safeAreaInset(edge: .bottom, spacing: 0) { if let d = detail { bottomBar(d) } }
    .toolbar(.hidden, for: .navigationBar)
    .hidesQuadTabBar()
    .task(id: id) {
      await load()
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(10))
          await load()
        } catch { break }
      }
    }
    .refreshable { await load() }
    .quickLookPreview($preview)
    .sheet(isPresented: $showOffer) {
      if let d = detail {
        OfferEditor(conversationID: id, listing: d.listing, counter: counter) {
          Task { await load() }
        }
      }
    }
    .confirmationDialog("Share a document", isPresented: $sharing, titleVisibility: .visible) {
      Button("Choose a PDF or photo") { picking = true }
    } message: {
      Text(
        "Both of you can see what is shared here. Your lease and ID belong in your private checks, not in a conversation."
      )
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

  // MARK: Top

  private var header: some View {
    VStack(spacing: 8) {
      HStack(spacing: 10) {
        Button {
          dismiss()
        } label: {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.quadIcon).accessibilityLabel("Back")
        if let d = detail {
          NavigationLink {
            MemberView(id: d.peer.id)
          } label: {
            HStack(spacing: 10) {
              QuadAvatar(name: d.peer.name, id: d.peer.id)
              VStack(alignment: .leading, spacing: 2) {
                Text(d.peer.name).font(.headline.weight(.heavy)).lineLimit(1)
                if let identity = ChatText.identity(d.peer.identity) {
                  Label(
                    identity.text,
                    systemImage: identity.checked ? "checkmark.shield.fill" : "shield"
                  )
                  .labelStyle(.titleAndIcon).font(.caption.weight(.bold))
                  .foregroundStyle(identity.checked ? Color.quadGreenText : Color.quadMuted)
                }
              }
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain).accessibilityIdentifier("conversation-peer")
          MemberSafetyActions(memberID: d.peer.id, menu: true)
        } else {
          Spacer()
        }
      }
      if let d = detail { place(d.listing) }
    }
    .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 8)
    .background(Color.quadGround)
  }

  private func place(_ listing: Listing) -> some View {
    NavigationLink {
      ListingView(listing: listing)
    } label: {
      HStack(spacing: 10) {
        RemoteImage(path: listing.images.first).frame(width: 46, height: 46)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(listing.title).font(.subheadline.weight(.heavy)).lineLimit(1)
          Text(
            "\(dollars(listing.price)) / month · \(QuadFormat.dateRange(listing.startDate, listing.endDate))"
          )
          .font(.caption).foregroundStyle(Color.quadMuted).lineLimit(1)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.subheadline.weight(.bold))
          .foregroundStyle(Color.quadMuted).accessibilityHidden(true)
      }
      .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 8)
      .quadCard(radius: 20)
    }
    .buttonStyle(.plain).accessibilityIdentifier("conversation-place")
  }

  // MARK: The thread

  @ViewBuilder private func row(_ item: ChatItem, _ d: ConversationDetail) -> some View {
    switch item {
    case .day(let label):
      Text(label).font(.caption.weight(.bold)).foregroundStyle(Color.quadMuted)
        .padding(.top, 6).accessibilityAddTraits(.isHeader)
    case .message(_, let body, let mine):
      bubble(body, mine: mine)
    case .offer(let offerID):
      if let offer = d.offers.first(where: { $0.id == offerID }) { offerCard(offer, d) }
    case .document(let documentID, let name, let mine):
      Button {
        open(documentID, name)
      } label: {
        Label(name, systemImage: "doc.fill").lineLimit(1)
      }
      .buttonStyle(.quadSecondary)
      .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    case .note(_, let text):
      Text(text).font(.caption).foregroundStyle(Color.quadMuted).multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    case .booking(let bookingID):
      if let booking = d.bookings.first(where: { $0.id == bookingID }) { bookingCard(booking) }
    }
  }

  /// What was said. Mine sit on the right in the orange tint; theirs on the left in white. The
  /// one tight corner points at whoever said it.
  private func bubble(_ text: String, mine: Bool) -> some View {
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: mine ? 22 : 8, bottomLeadingRadius: 22,
      bottomTrailingRadius: mine ? 8 : 22, topTrailingRadius: 22, style: .continuous)
    return Text(text).font(.callout.weight(mine ? .semibold : .regular))
      .padding(.horizontal, 15).padding(.vertical, 11)
      .background(mine ? Color(quad: 0xFFD9C4) : Color.white, in: shape)
      .overlay { if !mine { shape.strokeBorder(Color.quadInk.opacity(0.06)) } }
      .frame(maxWidth: 290, alignment: mine ? .trailing : .leading)
      .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
  }

  private func offerCard(_ offer: Offer, _ d: ConversationDetail) -> some View {
    let card = ChatText.offer(
      offer, viewerID: state.user?.id, peerName: d.peer.name, roomType: d.listing.roomType)
    let mine = offer.proposedBy == state.user?.id
    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(card.heading).font(.caption.weight(.heavy)).foregroundStyle(Color.quadMuted)
        Spacer(minLength: 8)
        QuadChip(
          text: card.status,
          kind: card.tone == .good ? .good : card.tone == .waiting ? .note : .plain)
      }
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(card.amount).font(.title2.weight(.heavy))
        Text("/ month").font(.footnote.weight(.bold)).foregroundStyle(Color.quadMuted)
      }
      .accessibilityElement(children: .combine)
      Text(card.terms).font(.footnote).foregroundStyle(Color.quadMuted)
      if !card.actions.isEmpty {
        HStack(spacing: 8) {
          ForEach(card.actions, id: \.self) { action in offerButton(action, offer) }
        }
        .padding(.top, 2).disabled(busy)
      }
    }
    .padding(12).frame(maxWidth: 310, alignment: .leading).quadCard(radius: 22)
    .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
  }

  @ViewBuilder private func offerButton(_ action: ChatText.OfferAction, _ offer: Offer)
    -> some View
  {
    switch action {
    case .withdraw:
      Button("Withdraw") { act("/api/offers/\(offer.id)/withdraw") }
        .buttonStyle(QuadSecondaryButtonStyle(wide: true, fill: .quadWell))
    case .accept:
      Button("Accept") { act("/api/offers/\(offer.id)/accept") }.buttonStyle(.quadPrimary)
    case .counter:
      Button("Counter") {
        counter = offer
        showOffer = true
      }
      .buttonStyle(QuadSecondaryButtonStyle(fill: .quadWell))
    case .decline:
      Button("Decline") { act("/api/offers/\(offer.id)/decline") }
        .buttonStyle(QuadSecondaryButtonStyle(fill: .quadWell))
    }
  }

  private func bookingCard(_ b: Booking) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Reservation").font(.caption.weight(.heavy)).foregroundStyle(Color.quadMuted)
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(dollars(b.amount)).font(.title2.weight(.heavy))
        Text("/ month").font(.footnote.weight(.bold)).foregroundStyle(Color.quadMuted)
      }
      .accessibilityElement(children: .combine)
      Text(QuadFormat.dateRange(b.startDate, b.endDate)).font(.footnote)
        .foregroundStyle(Color.quadMuted)
      QuadFlow(spacing: 6) {
        QuadChip(text: ChatText.plain(b.status))
        QuadChip(text: "Payment: " + ChatText.plain(b.paymentStatus).lowercased())
        if b.disputeStatus != "none" {
          QuadChip(text: "Issue " + ChatText.plain(b.disputeStatus).lowercased(), kind: .note)
        }
      }
      if b.disputeStatus != "none", let reason = b.disputeReason, !reason.isEmpty {
        Text(reason).font(.footnote)
      }
      Text("Legal signing and live payments are not available yet.").font(.caption)
        .foregroundStyle(Color.quadMuted)
      if b.buyerId == state.user?.id {
        HStack(spacing: 8) {
          Button("Confirm move-in") {
            act("/api/bookings/\(b.id)/action", ["action": "confirm-move-in"])
          }
          .buttonStyle(.quadPrimary)
          Button("Report an issue") { dispute = b }
            .buttonStyle(QuadSecondaryButtonStyle(fill: .quadWell))
        }
        .disabled(busy)
      }
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading).quadCard(radius: 22)
  }

  // MARK: Bottom

  private func bottomBar(_ d: ConversationDetail) -> some View {
    let first = QuadFormat.firstName(d.peer.name)
    let empty = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return VStack(spacing: 8) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(ChatText.quickReplies(viewerOwnsPlace: d.listing.ownerId == state.user?.id)) {
            reply in
            Button(reply.label) {
              if let text = reply.text {
                message = text
              } else {
                counter = nil
                showOffer = true
              }
            }
            .buttonStyle(.quadSecondary)
          }
        }
        .padding(.horizontal, 16)
      }
      .quadSidewaysScroll()
      HStack(alignment: .bottom, spacing: 8) {
        Button {
          sharing = true
        } label: {
          Image(systemName: "plus").font(.body.weight(.bold)).frame(width: 46, height: 46)
            .background(Color.quadWell, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel("Share a document")
        TextField("Message \(first)", text: $message, axis: .vertical).lineLimit(1...4)
          .font(.callout).padding(.horizontal, 16).padding(.vertical, 12)
          .background(Color.quadWell, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
          .accessibilityIdentifier("conversation-message")
        Button {
          send()
        } label: {
          Image(systemName: "arrow.up").font(.body.weight(.heavy)).frame(width: 48, height: 48)
            .background(Color.quadOrange, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel("Send").disabled(busy || empty)
        .opacity(busy || empty ? 0.45 : 1)
      }
      .padding(10)
      .quadCard(radius: 34)
      .padding(.horizontal, 12)
    }
    .padding(.top, 8).padding(.bottom, 8)
    .quadBarFade()
  }

  // MARK: Doing things

  func load() async {
    do {
      let r: ConversationDetail = try await state.api.get("/api/conversations/\(id)")
      try Task.checkCancellation()
      detail = r
      error = ""
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }
  private func open(_ documentID: String, _ name: String) {
    Task {
      do {
        preview = try await state.api.download("/api/chat-documents/\(documentID)", name: name)
      } catch { self.error = error.localizedDescription }
    }
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
          Picker("Kind", selection: $kind) {
            Text("Offer").tag("offer")
            Text("Request at the asking price").tag("request")
          }
        }
        Text(
          "An accepted offer reserves dates only when the listing passes the required checks. Payment and signing remain unavailable."
        ).font(.caption)
        if !error.isEmpty { Text(error).foregroundStyle(.red) }
        Button(counter == nil ? "Send offer" : "Send counteroffer") {
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
      }.navigationTitle(counter == nil ? "Make an offer" : "Counteroffer")
        .navigationBarTitleDisplayMode(.inline).tint(.quadOrangeDeep)
        .toolbar { Button("Cancel") { dismiss() } }.onAppear {
        amount = String(counter?.amount ?? listing.price)
        start = parseDay(counter?.startDate ?? listing.startDate)
        end = parseDay(counter?.endDate ?? listing.endDate)
      }
    }
  }
}
