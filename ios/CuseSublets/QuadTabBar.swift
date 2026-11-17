import SwiftUI

/// What the Post button was asked to start. The You tab owns the editors and opens the right one.
enum PostIntent: Equatable {
  case listing, search
}

/// The floating bar at the bottom of the app: four places and a raised Post button in the middle.
struct QuadTabBar: View {
  @Binding var selection: Int
  let post: () -> Void
  /// Room each screen leaves at its bottom so its last line clears the bar and the Post button.
  static let reservedHeight: CGFloat = 86

  var body: some View {
    HStack(spacing: 0) {
      tab(.home)
      tab(.matches)
      Button(action: post) {
        Image(systemName: "plus").font(.title2.weight(.bold)).foregroundStyle(Color.quadInk)
          .frame(width: 56, height: 56)
          .background {
            ZStack {
              Circle().fill(Color(quad: 0xD9480F)).offset(y: 3)
              Circle().fill(Color.quadOrange)
            }
          }
      }
      .buttonStyle(QuadLiftButtonStyle())
      .offset(y: -14)
      .frame(maxWidth: .infinity)
      .accessibilityLabel("Post a place or say what you're looking for")
      .accessibilityIdentifier("tab-post")
      tab(.inbox)
      tab(.you)
    }
    .padding(.horizontal, 6)
    .frame(height: 64)
    .background(.white, in: Capsule())
    .shadow(color: Color(quad: 0x1F2937).opacity(0.12), radius: 14, y: 6)
    .padding(.horizontal, 12)
    .padding(.top, 14)
    .padding(.bottom, 4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("quad-tab-bar")
  }

  private func tab(_ tab: QuadTab) -> some View {
    let selected = selection == tab.rawValue
    return Button {
      selection = tab.rawValue
    } label: {
      VStack(spacing: 3) {
        Image(systemName: selected ? tab.symbol + ".fill" : tab.symbol)
          .font(.system(size: 20, weight: .semibold)).frame(height: 24)
        Text(tab.title).font(.caption2.weight(.bold))
      }
      .foregroundStyle(selected ? Color.quadOrangeDeep : Color.quadMuted)
      .frame(maxWidth: .infinity, minHeight: 52)
      .contentShape(Rectangle())
    }
    .buttonStyle(QuadLiftButtonStyle())
    .accessibilityLabel(tab.title)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
    .accessibilityIdentifier(tab.identifier)
  }
}

/// Press feedback for the tab bar's own buttons, which draw themselves.
private struct QuadLiftButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
      .animation(
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.5),
        value: configuration.isPressed)
  }
}

/// Lays chips out left to right and wraps them onto new lines.
struct QuadFlow: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(subviews, width: proposal.width ?? .infinity)
    return CGSize(width: proposal.width ?? rows.width, height: rows.height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for (subview, point) in zip(subviews, arrange(subviews, width: bounds.width).points) {
      subview.place(
        at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
    }
  }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> (
    points: [CGPoint], width: CGFloat, height: CGFloat
  ) {
    var points: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0 && x + size.width > width {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      points.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      widest = max(widest, x - spacing)
    }
    return (points, widest, y + rowHeight)
  }
}
