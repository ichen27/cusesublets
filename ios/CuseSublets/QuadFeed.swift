import SwiftUI

/// A place in the home feed. It leads with the person, then the photo and price.
struct QuadListingCard: View {
  @EnvironmentObject var state: AppState
  let listing: Listing
  /// The place fits the signed-in person's own housing search.
  var fits = false

  private var own: Bool { state.user?.id == listing.ownerId }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      NavigationLink {
        ListingView(listing: listing)
      } label: {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 10) {
            QuadAvatar(name: listing.hostName, id: listing.ownerId)
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(listing.hostName).font(.subheadline.weight(.heavy))
                if listing.hostIdentity == "verified" {
                  QuadChip(text: "ID checked", symbol: "checkmark.shield", kind: .good)
                }
              }
              Text(QuadFormat.subleasing(in: listing.neighborhood)).font(.footnote)
                .foregroundStyle(Color.quadMuted)
            }
            Spacer(minLength: 0)
          }
          RemoteImage(path: listing.images.first)
            .frame(height: 176).frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topLeading) {
              HStack(spacing: 6) {
                if listing.sample { QuadChip(text: "Sample", kind: .dark) }
                if fits { QuadChip(text: "Fits your search", kind: .good) }
              }.padding(10)
            }
            .overlay(alignment: .bottomTrailing) {
              QuadChip(text: dollars(listing.price) + " / mo", kind: .price).padding(10)
            }
          VStack(alignment: .leading, spacing: 4) {
            Text(listing.title).font(.headline.weight(.heavy)).multilineTextAlignment(.leading)
            Text(
              "\(listing.roomType) · \(QuadFormat.dateRange(listing.startDate, listing.endDate))"
            ).font(.footnote).foregroundStyle(Color.quadMuted)
            if listing.leaseStatus == "verified" {
              Label("Lease checked by staff", systemImage: "checkmark")
                .font(.caption.weight(.bold)).foregroundStyle(Color.quadGreenText)
            }
          }
          .padding(.horizontal, 2)
        }
        .foregroundStyle(Color.quadInk)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      HStack {
        Spacer()
        if own {
          NavigationLink("Manage") { ListingManageView(listing: listing) }
            .buttonStyle(.quadSecondary)
        } else {
          Button("Message") { Task { await state.contact(listingID: listing.id) } }
            .buttonStyle(.quadPrimary)
            .accessibilityLabel("Message \(listing.hostName)")
        }
      }
    }
    .padding(12)
    .quadCard()
  }
}

/// Someone looking for a place, in the home feed.
struct QuadSearchCard: View {
  let search: HousingSearch
  /// One of the signed-in person's own places fits this search.
  var fits = false

  var body: some View {
    NavigationLink {
      SearchDetailView(search: search)
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          QuadAvatar(name: search.ownerName, id: search.ownerId)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(search.ownerName).font(.subheadline.weight(.heavy))
              if search.ownerIdentity == "verified" {
                QuadChip(text: "ID checked", symbol: "checkmark.shield", kind: .good)
              }
            }
            Text("Looking for a place").font(.footnote).foregroundStyle(Color.quadMuted)
          }
          Spacer(minLength: 0)
          if fits { QuadChip(text: "Fits your place", kind: .good) }
        }
        if !search.introduction.isEmpty {
          Text(search.introduction).font(.subheadline).lineLimit(3)
            .multilineTextAlignment(.leading)
        }
        QuadFlow {
          QuadChip(text: "Up to " + dollars(search.maxBudget))
          QuadChip(text: QuadFormat.dateRange(search.startDate, search.endDate))
          QuadChip(text: search.roomType)
          ForEach(search.areas.prefix(2)) { QuadChip(text: $0.label) }
        }
      }
      .foregroundStyle(Color.quadInk)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .quadCard()
  }
}

/// One choice in the row above the feed. The chosen one is dark.
struct QuadFilterChip: View {
  let title: String
  var symbol: String?
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if let symbol { Image(systemName: symbol).imageScale(.small) }
        Text(title)
      }
      .font(.subheadline.weight(.bold))
      .foregroundStyle(selected ? Color.white : Color.quadInk)
      .padding(.horizontal, 15).frame(minHeight: 38)
      .background(selected ? Color.quadInk : Color.white, in: Capsule())
      .overlay(Capsule().strokeBorder(Color.quadInk.opacity(selected ? 0 : 0.08)))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}
