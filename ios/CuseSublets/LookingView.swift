import SwiftUI

/// "What you're looking for": your saved search, whether it is on, how many places fit it right
/// now, and one row per answer. A row opens the step that changes it.
struct LookingView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var search: HousingSearch?
  @State private var places: [Listing]?
  @State private var loaded = false
  @State private var busy = false
  @State private var error = ""
  @State private var editing: Opening?

  /// The steps, opened on one of them. A new search has no saved answers behind it.
  private struct Opening: Identifiable {
    let step: SearchStep
    var id: Int { step.rawValue }
  }

  private var isOn: Bool { search?.status == "active" }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "chevron.left")
          }
          .buttonStyle(.quadIcon).accessibilityLabel("Back")
          Text("What you're looking for").font(.title2.weight(.heavy))
            .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, 4)
        if !error.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text(error).font(.subheadline)
            Button("Try again") { Task { await load() } }.buttonStyle(.quadSecondary)
          }
        }
        if let search {
          status(search)
          rows(search)
          Text(
            "Changes update your matches straight away. Turn the search off when you have found a place."
          )
          .font(.footnote).foregroundStyle(Color.quadMuted)
        } else if loaded && error.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            Text("You haven't said what you're looking for").font(.headline.weight(.heavy))
            Text("Three short steps: your dates and budget, the kind of place, and a line about you.")
              .font(.subheadline).foregroundStyle(Color.quadMuted)
            Button("Say what I'm looking for") { editing = .init(step: .dates) }
              .buttonStyle(.quadPrimaryWide)
          }
          .padding(16).frame(maxWidth: .infinity, alignment: .leading).quadCard(radius: 22)
        } else if !loaded {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }
      }
      .padding(.horizontal, 16).padding(.bottom, 16)
    }
    .foregroundStyle(Color.quadInk)
    .background(Color.quadGround.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .task(id: state.user?.id) { await load() }
    .refreshable { await load() }
    .fullScreenCover(item: $editing, onDismiss: { Task { await load() } }) { opening in
      NavigationStack { SearchFlow(search: search, startAt: opening.step, onSaved: {}) }
    }
  }

  private func status(_ search: HousingSearch) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(isOn ? "Your search is on" : "Your search is off")
            .font(.headline.weight(.heavy))
          Text(
            isOn
              ? "People whose places fit can find you and message you."
              : "Nobody can find it, and nothing new is matched to it."
          )
          .font(.subheadline).foregroundStyle(Color.quadMuted)
        }
        Spacer(minLength: 8)
        Toggle(
          "Search on",
          isOn: Binding(get: { isOn }, set: { on in Task { await turn(on) } })
        )
        .labelsHidden().tint(.quadGreen).disabled(busy || search.status == "removed")
        .accessibilityIdentifier("search-on")
      }
      if isOn, let places {
        Divider()
        HStack {
          Text(
            SearchText.fitsNow(
              SearchForm(search: search).fits(places, viewerID: state.user?.id))
          )
          .font(.subheadline.weight(.bold)).foregroundStyle(Color.quadGreenText)
          Spacer(minLength: 8)
          Button("See matches") { state.tab = QuadTab.matches.rawValue }
            .buttonStyle(.quadSecondary)
        }
      }
    }
    .padding(16).quadCard(radius: 22)
  }

  private func rows(_ search: HousingSearch) -> some View {
    let rows = SearchText.rows(search)
    return VStack(spacing: 0) {
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
        Button {
          editing = .init(step: row.step)
        } label: {
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
              Text(row.title).font(.caption.weight(.bold)).foregroundStyle(Color.quadMuted)
              Text(row.value).font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote.weight(.bold))
              .foregroundStyle(Color.quadMuted).accessibilityHidden(true)
          }
          .padding(.horizontal, 16).padding(.vertical, 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if index < rows.count - 1 { Divider().padding(.leading, 16) }
      }
    }
    .quadCard(radius: 22)
  }

  private func load() async {
    guard state.user != nil else { return }
    do {
      let mine: MySearchResponse = try await state.api.get("/api/my-search")
      search = mine.search
      error = ""
    } catch { self.error = error.localizedDescription }
    loaded = true
    // The count is a help, not a need.
    if let feed: ListingsResponse = try? await state.api.get("/api/listings") {
      places = feed.listings
    }
  }

  private func turn(_ on: Bool) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      try await state.api.act("/api/my-search/status", ["status": on ? "active" : "paused"])
      await load()
    } catch { self.error = error.localizedDescription }
  }
}
