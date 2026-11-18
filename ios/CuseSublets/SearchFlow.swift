import MapKit
import SwiftUI

/// Saying what you are looking for, in three steps: dates and budget, the place, about you.
/// Finishing turns the search on, so places that fit show up under Matches and their owners can
/// find you. Opened on a saved search it changes that search instead.
struct SearchFlow: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) private var dismiss
  /// The saved search being changed, or nothing when this is a new one.
  let search: HousingSearch?
  var startAt = SearchStep.dates
  let onSaved: () -> Void

  @State private var form = SearchForm()
  @State private var step = SearchStep.dates
  /// The public places, read once, to say how many fit the answers so far.
  @State private var places: [Listing]?
  /// The revision of an unfinished search saved elsewhere, removed once this one is saved.
  @State private var draftRevision: Int?
  @State private var loaded = false
  @State private var busy = false
  @State private var problem = ""
  @State private var drawing = false

  private var editing: Bool { search != nil }

  var body: some View {
    VStack(spacing: 0) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if loaded {
            switch step {
            case .dates: datesStep
            case .place: placeStep
            case .about: aboutStep
            }
          } else {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
          }
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      // These steps cover the tab bar, so they drop the room a tab reserves for it.
      .contentMargins(.bottom, 0, for: .scrollContent)
      .scrollDismissesKeyboard(.interactively)
      bar
    }
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
    .interactiveDismissDisabled(busy)
    .task { await load() }
    // A message about an answer stops applying once the answers change.
    .onChange(of: form) { problem = "" }
    .sheet(isPresented: $drawing) {
      AreaDrawView { area in form.add(area: area) }
    }
  }

  // MARK: Frame

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Button {
          if !editing, let previous = SearchStep(rawValue: step.rawValue - 1) {
            problem = ""
            step = previous
          } else {
            dismiss()
          }
        } label: {
          Image(systemName: !editing && step != .dates ? "chevron.left" : "xmark")
        }
        .buttonStyle(.quadIcon)
        .accessibilityLabel(!editing && step != .dates ? "Back" : "Close").disabled(busy)
        Spacer()
      }
      HStack(spacing: 6) {
        ForEach(SearchStep.allCases, id: \.self) { item in
          Capsule()
            .fill(item.rawValue <= step.rawValue ? Color.quadGreen : Color.quadInk.opacity(0.1))
            .frame(height: 6)
        }
      }.accessibilityHidden(true)
      Text(step.progress).font(.caption.weight(.bold)).foregroundStyle(Color.quadMuted)
      Text(step.title).font(.title.weight(.heavy)).accessibilityAddTraits(.isHeader)
    }
    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
  }

  private var bar: some View {
    VStack(spacing: 10) {
      if !problem.isEmpty {
        Text(problem).font(.footnote.weight(.semibold)).foregroundStyle(Color(quad: 0xB42318))
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("flow-problem")
      }
      if let places, loaded {
        Text(SearchText.fits(form.fits(places, viewerID: state.user?.id)))
          .font(.footnote.weight(.bold)).foregroundStyle(Color.quadGreenText)
          .padding(.horizontal, 12).padding(.vertical, 6)
          .background(Color.quadGreenTint, in: Capsule())
          .accessibilityIdentifier("search-fits")
      }
      Button(primaryTitle) { Task { await primary() } }
        .buttonStyle(.quadPrimaryWide).disabled(busy || !loaded)
      if editing, let next = SearchStep(rawValue: step.rawValue + 1) {
        Button("Next: \(next.label)") { move(to: next) }
          .buttonStyle(QuadSecondaryButtonStyle(wide: true)).disabled(busy || !loaded)
      }
    }
    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
    .background(Color.quadGround)
  }

  private var primaryTitle: String {
    if editing { return "Save changes" }
    return step == .about ? "Finish and see my matches" : "Continue"
  }

  // MARK: Steps

  @ViewBuilder private var datesStep: some View {
    QuadFlow(spacing: 8) {
      ForEach(SearchTerm.allCases) { term in
        QuadChoice(title: term.rawValue, selected: form.term(today: Date()) == term) {
          form.choose(term, today: Date())
        }
      }
    }
    HStack(spacing: 12) {
      dateBox("Move in", $form.start)
      dateBox("Move out", $form.end)
    }
    Text("What can you spend each month?").font(.title3.weight(.heavy))
      .accessibilityAddTraits(.isHeader).padding(.top, 6)
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(SearchText.budget(form.budget)).font(.system(size: 34, weight: .heavy))
          .monospacedDigit().accessibilityIdentifier("search-budget")
        Text("at most").font(.subheadline.weight(.bold)).foregroundStyle(Color.quadMuted)
      }
      Slider(
        value: Binding(
          get: { Double(form.budget) },
          set: {
            form.budget =
              Int(($0 / Double(SearchForm.budgetStep)).rounded()) * SearchForm.budgetStep
          }),
        in: Double(form.budgetBounds.lowerBound)...Double(form.budgetBounds.upperBound),
        step: Double(SearchForm.budgetStep)
      )
      .tint(.quadOrange).accessibilityLabel("The most you can spend each month")
      .accessibilityValue(SearchText.budget(form.budget))
      HStack {
        Text(SearchText.budget(form.budgetBounds.lowerBound))
        Spacer()
        Text(SearchText.budget(form.budgetBounds.upperBound))
      }
      .font(.caption.weight(.bold)).foregroundStyle(Color.quadMuted).accessibilityHidden(true)
    }
    .padding(16).quadCard(radius: 22)
  }

  private func dateBox(_ title: String, _ date: Binding<Date>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      caption(title)
      DatePicker(title, selection: date, displayedComponents: .date).labelsHidden()
        .tint(.quadOrangeDeep)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(QuadFieldBox(vertical: 10))
  }

  @ViewBuilder private var placeStep: some View {
    VStack(alignment: .leading, spacing: 8) {
      caption("Kind of place")
      QuadFlow(spacing: 8) {
        ForEach(SearchForm.kinds, id: \.value) { kind in
          QuadChoice(title: kind.label, selected: form.kind == kind.value) {
            form.kind = kind.value
          }
        }
      }
    }
    VStack(alignment: .leading, spacing: 8) {
      caption("Where")
      QuadFlow(spacing: 8) {
        QuadChoice(title: SearchForm.anywhere.label, selected: form.isAnywhere) {
          if form.isAnywhere {
            form.remove(areaID: SearchForm.anywhere.id)
          } else {
            form.chooseAnywhere()
          }
        }
        ForEach(form.areas.filter { $0.id != SearchForm.anywhere.id }) { area in
          Button {
            form.remove(areaID: area.id)
          } label: {
            HStack(spacing: 5) {
              Text(area.label)
              Image(systemName: "xmark").imageScale(.small)
            }
            .font(.subheadline.weight(.bold)).foregroundStyle(Color.quadGreenText)
            .padding(.horizontal, 14).frame(minHeight: 40)
            .background(Color.quadGreenTint, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.quadGreen.opacity(0.35)))
          }
          .buttonStyle(.plain).accessibilityLabel("Remove \(area.label)")
        }
        Button {
          drawing = true
        } label: {
          Label("Draw on the map", systemImage: "scribble.variable")
        }
        .buttonStyle(.quadSecondary).disabled(!form.canAddArea)
      }
      Text("Draw up to \(SearchForm.areaLimit) areas, or leave it at anywhere.")
        .font(.footnote).foregroundStyle(Color.quadMuted)
    }
    VStack(alignment: .leading, spacing: 8) {
      caption("Must-haves")
      QuadFlow(spacing: 8) {
        ForEach(form.mustHaveChoices, id: \.self) { item in
          QuadChoice(title: item, selected: form.mustHaves.contains(item)) {
            form.toggle(mustHave: item)
          }
        }
      }
      Text(
        "Must-haves hide places that lack them, so keep the list short. You can change all of this later."
      )
      .font(.footnote).foregroundStyle(Color.quadMuted)
    }
  }

  @ViewBuilder private var aboutStep: some View {
    Text("People subleasing their place see this before they reply to you.")
      .font(.subheadline).foregroundStyle(Color.quadMuted)
    VStack(alignment: .leading, spacing: 6) {
      caption("Say hello")
      TextField(
        "A line or two about you and why you need a place", text: $form.introduction,
        axis: .vertical
      )
      .lineLimit(4...8).accessibilityIdentifier("search-hello").modifier(QuadFieldBox())
      Text("\(form.introduction.count) of \(SearchForm.introductionLimit)")
        .font(.caption.weight(.bold))
        .foregroundStyle(
          form.introduction.count > SearchForm.introductionLimit
            ? Color(quad: 0xB42318) : Color.quadMuted
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    VStack(spacing: 0) {
      profileLink(
        "person.crop.circle.badge.plus", "Add a photo",
        "A clear photo of your face. It shows on your profile.")
      Divider().padding(.leading, 56)
      profileLink(
        "checkmark.shield", "Get the \u{201C}ID checked\u{201D} badge",
        "Takes a few minutes. You can do it later.")
    }
    .quadCard(radius: 22)
  }

  private func profileLink(_ symbol: String, _ title: String, _ text: String) -> some View {
    NavigationLink {
      ProfileEditor()
    } label: {
      HStack(spacing: 12) {
        Image(systemName: symbol).font(.title3).foregroundStyle(Color.quadGreen)
          .frame(width: 32).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.subheadline.weight(.heavy))
          Text(text).font(.footnote).foregroundStyle(Color.quadMuted)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.footnote.weight(.bold))
          .foregroundStyle(Color.quadMuted).accessibilityHidden(true)
      }
      .padding(14).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func caption(_ text: String) -> some View {
    Text(text).font(.caption.weight(.bold)).foregroundStyle(Color.quadMuted)
  }

  // MARK: Doing things

  private func load() async {
    guard !loaded else { return }
    if let search {
      form = SearchForm(search: search)
      step = startAt
    }
    // An unfinished search may be waiting from the website or an older version of the app.
    if let saved: DraftResponse = try? await state.api.get("/api/drafts/search") {
      draftRevision = saved.revision
      if search == nil, let draft = saved.draft {
        form.apply(draft: draft.data.mapValues(\.value))
      }
    }
    loaded = true
    // The count is a help, not a need: without the places the steps still work.
    if let feed: ListingsResponse = try? await state.api.get("/api/listings") {
      places = feed.listings
    }
  }

  private func move(to next: SearchStep) {
    if let stop = form.problem(for: step) {
      problem = stop
      return
    }
    problem = ""
    step = next
  }

  private func primary() async {
    if let stop = form.problem(for: step) {
      problem = stop
      return
    }
    if !editing, let next = SearchStep(rawValue: step.rawValue + 1) {
      problem = ""
      step = next
      return
    }
    // Saving sends every step's answers, so each has to hold up, not only the one on screen.
    if let stop = SearchStep.allCases.compactMap({ form.problem(for: $0) }).first {
      problem = stop
      return
    }
    busy = true
    defer { busy = false }
    do {
      // A new search goes on at once; a saved one keeps whether it was on or off.
      let body = form.payload(active: search.map { $0.status == "active" } ?? true)
      _ = try await state.api.publishHousingSearch(body, draftRevision: draftRevision ?? 0)
      onSaved()
      dismiss()
      if !editing { state.tab = QuadTab.matches.rawValue }
    } catch { problem = error.localizedDescription }
  }
}

/// Drawing one area on the map: tap its corners, name it, add it.
struct AreaDrawView: View {
  @Environment(\.dismiss) private var dismiss
  let onAdd: (SearchArea) -> Void
  @State private var corners: [GeoPoint] = []
  @State private var name = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Draw an area").font(.title2.weight(.heavy)).accessibilityAddTraits(.isHeader)
        Spacer()
        Button("Cancel") { dismiss() }.font(.subheadline.weight(.bold))
          .foregroundStyle(Color.quadLink)
      }
      Text("Tap at least three corners around the area you would live in, then name it.")
        .font(.subheadline).foregroundStyle(Color.quadMuted)
      MapReader { proxy in
        Map(
          initialPosition: .region(
            MKCoordinateRegion(
              center: .init(latitude: 43.04, longitude: -76.13),
              span: .init(latitudeDelta: 0.08, longitudeDelta: 0.08)))
        ) {
          if corners.count > 2 {
            MapPolygon(coordinates: corners.map { .init(latitude: $0.lat, longitude: $0.lng) })
              .foregroundStyle(Color.quadOrange.opacity(0.2))
          }
          if corners.count > 1 {
            MapPolyline(coordinates: corners.map { .init(latitude: $0.lat, longitude: $0.lng) })
              .stroke(Color.quadOrange, lineWidth: 3)
          }
          ForEach(Array(corners.enumerated()), id: \.offset) { _, corner in
            Annotation("", coordinate: .init(latitude: corner.lat, longitude: corner.lng)) {
              Circle().fill(Color.quadOrange).frame(width: 12, height: 12)
                .overlay(Circle().stroke(.white, lineWidth: 2))
            }
          }
        }
        .onTapGesture { point in
          if corners.count < 25, let c = proxy.convert(point, from: .local) {
            corners.append(.init(lat: c.latitude, lng: c.longitude))
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
      .accessibilityLabel("Map. Tap to add a corner.")
      TextField("Name this area, such as Westcott", text: $name).modifier(QuadFieldBox())
      HStack(spacing: 10) {
        Button("Undo corner") { if !corners.isEmpty { corners.removeLast() } }
          .buttonStyle(.quadSecondary).disabled(corners.isEmpty)
        Button("Add area") {
          onAdd(
            .init(
              id: UUID().uuidString, label: name.trimmingCharacters(in: .whitespaces),
              points: corners))
          dismiss()
        }
        .buttonStyle(.quadPrimaryWide)
        .disabled(corners.count < 3 || name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .foregroundStyle(Color.quadInk)
    .background(Color.quadGround.ignoresSafeArea())
  }
}

/// The question a new member is asked once, right after creating an account.
struct WelcomeView: View {
  @EnvironmentObject var state: AppState
  @Environment(\.dismiss) private var dismiss
  @State private var choice: PostIntent?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 10) {
        QuadLogo()
        Text("Quad").font(.title3.weight(.heavy))
        Spacer()
        Button("Skip for now") { dismiss() }.font(.subheadline.weight(.bold))
          .foregroundStyle(Color.quadLink)
      }
      Text("What brings you to Quad?").font(.largeTitle.weight(.heavy))
        .accessibilityAddTraits(.isHeader).padding(.top, 12)
      Text("Pick one to start. You can do the other later from You.")
        .font(.subheadline).foregroundStyle(Color.quadMuted)
      option(
        .search, "magnifyingglass", "I'm looking for a place",
        "Tell us your dates and budget and we line up places that fit.")
      option(
        .listing, "house", "I'm subleasing my place",
        "List it, scan it, and meet people whose plans fit yours.")
      Spacer()
      Button("Continue") {
        state.welcomeChoice = choice
        dismiss()
      }
      .buttonStyle(.quadPrimaryWide).disabled(choice == nil)
    }
    .padding(20)
    .foregroundStyle(Color.quadInk)
    .background(Color.quadGround.ignoresSafeArea())
  }

  private func option(_ intent: PostIntent, _ symbol: String, _ title: String, _ text: String)
    -> some View
  {
    let selected = choice == intent
    return Button {
      choice = intent
    } label: {
      HStack(spacing: 14) {
        Image(systemName: symbol).font(.title2.weight(.semibold))
          .foregroundStyle(selected ? Color.quadGreenText : Color.quadInk)
          .frame(width: 52, height: 52)
          .background(selected ? Color.quadGreenTint : Color.quadWell, in: Circle())
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.headline.weight(.heavy))
          Text(text).font(.subheadline).foregroundStyle(Color.quadMuted)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 0)
        Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3)
          .foregroundStyle(selected ? Color.quadGreen : Color.quadInk.opacity(0.2))
          .accessibilityHidden(true)
      }
      .padding(16).quadCard(radius: 24)
      .overlay(
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .strokeBorder(selected ? Color.quadGreen : .clear, lineWidth: 2))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}
