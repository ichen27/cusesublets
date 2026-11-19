import SwiftUI

// The look of the redesigned app. Each colour has one job:
// orange is for doing (main buttons, prices), green is for yes and done (checks, selected
// answers, progress), and indigo is kept small (the logo, text, links).
extension Color {
  init(quad hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
  /// Page background.
  static let quadGround = Color(quad: 0xFAF7F2)
  /// Quiet fill inside a card: wells, unselected chips.
  static let quadWell = Color(quad: 0xF4F0E8)
  /// Text.
  static let quadInk = Color(quad: 0x1E1B4B)
  static let quadMuted = Color(quad: 0x5B5875)
  /// Main buttons and prices. Its label is `quadInk`; white on it is too hard to read.
  static let quadOrange = Color(quad: 0xFF5A1F)
  /// Orange that is dark enough for text and icons on white.
  static let quadOrangeDeep = Color(quad: 0xC2410C)
  static let quadOrangeTint = Color(quad: 0xFFE3D3)
  static let quadOrangeTintText = Color(quad: 0x9A3412)
  static let quadGreen = Color(quad: 0x15803D)
  static let quadGreenTint = Color(quad: 0xDCFCE7)
  static let quadGreenText = Color(quad: 0x166534)
  static let quadIndigo = Color(quad: 0x4F46E5)
  static let quadIndigoTint = Color(quad: 0xE0E7FF)
  static let quadIndigoText = Color(quad: 0x3730A3)
  static let quadLink = Color(quad: 0x4338CA)
  /// Stand-in behind a photo that has not loaded or does not exist.
  static let quadPhoto = Color(quad: 0xF1E9DD)
  // The scan screens are dark so the camera picture and the map stand out.
  /// Behind the scan map.
  static let quadScanGround = Color(quad: 0x17161C)
  /// Green that reads on the dark scan screens: scanned spots, the ring that fills, progress.
  static let quadScanGreen = Color(quad: 0x4ADE80)
  /// Body text on the dark scan screens.
  static let quadScanText = Color(quad: 0xCFCDC6)
}

/// Shrinks a control a little while it is pressed and springs it back, unless the person has
/// asked for less motion.
private struct QuadPress: ViewModifier {
  let pressed: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func body(content: Content) -> some View {
    content.scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
      .animation(
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.5), value: pressed)
  }
}

/// The one button on a screen that moves things forward: orange, with a darker lower edge so it
/// reads as pressable.
struct QuadPrimaryButtonStyle: ButtonStyle {
  /// Fills the width and stands taller, for the button at the bottom of a screen.
  var wide = false
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(wide ? .headline.weight(.heavy) : .subheadline.weight(.heavy))
      .foregroundStyle(Color.quadInk)
      .padding(.horizontal, wide ? 24 : 18)
      .frame(maxWidth: wide ? .infinity : nil, minHeight: wide ? 56 : 44)
      .background {
        ZStack {
          Capsule().fill(Color(quad: 0xD9480F)).offset(y: 3)
          Capsule().fill(Color.quadOrange)
        }
      }
      .opacity(enabled ? 1 : 0.45)
      .modifier(QuadPress(pressed: configuration.isPressed))
  }
}

/// Every other button: a flat white pill with a hairline.
struct QuadSecondaryButtonStyle: ButtonStyle {
  var wide = false
  var fill = Color.white
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.bold))
      .foregroundStyle(Color.quadInk)
      .padding(.horizontal, 16)
      .frame(maxWidth: wide ? .infinity : nil, minHeight: wide ? 50 : 44)
      .background(fill, in: Capsule())
      .overlay(Capsule().strokeBorder(Color.quadInk.opacity(0.08)))
      .opacity(enabled ? 1 : 0.45)
      .modifier(QuadPress(pressed: configuration.isPressed))
  }
}

/// A round icon button, 44 points across.
struct QuadIconButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.weight(.semibold))
      .foregroundStyle(Color.quadInk)
      .frame(width: 44, height: 44)
      .background(.white, in: Circle())
      .overlay(Circle().strokeBorder(Color.quadInk.opacity(0.08)))
      .modifier(QuadPress(pressed: configuration.isPressed))
  }
}

/// A dark pill for an action that sits on top of a photo.
struct QuadDarkButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.heavy))
      .foregroundStyle(.white)
      .padding(.horizontal, 18).frame(minHeight: 46)
      .background(Color.quadInk, in: Capsule())
      .modifier(QuadPress(pressed: configuration.isPressed))
  }
}

/// A button on a dark scan screen or over the camera: white on a translucent pill.
struct QuadOnDarkButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.heavy))
      .foregroundStyle(.white)
      .padding(.horizontal, 14).frame(minWidth: 44, minHeight: 44)
      .background(.white.opacity(0.14), in: Capsule())
      .opacity(enabled ? 1 : 0.45)
      .modifier(QuadPress(pressed: configuration.isPressed))
  }
}
extension ButtonStyle where Self == QuadOnDarkButtonStyle {
  static var quadOnDark: QuadOnDarkButtonStyle { .init() }
}
extension ButtonStyle where Self == QuadDarkButtonStyle {
  static var quadDark: QuadDarkButtonStyle { .init() }
}
extension ButtonStyle where Self == QuadPrimaryButtonStyle {
  static var quadPrimary: QuadPrimaryButtonStyle { .init() }
  static var quadPrimaryWide: QuadPrimaryButtonStyle { .init(wide: true) }
}
extension ButtonStyle where Self == QuadSecondaryButtonStyle {
  static var quadSecondary: QuadSecondaryButtonStyle { .init() }
}
extension ButtonStyle where Self == QuadIconButtonStyle {
  static var quadIcon: QuadIconButtonStyle { .init() }
}

extension View {
  /// Behind a floating bar at the bottom of a screen: fades whatever scrolls under it into the
  /// page colour, so nothing shows through below the bar.
  func quadBarFade() -> some View {
    background {
      LinearGradient(
        stops: [
          .init(color: Color.quadGround.opacity(0), location: 0),
          .init(color: Color.quadGround.opacity(0.94), location: 0.45),
          .init(color: Color.quadGround, location: 1),
        ], startPoint: .top, endPoint: .bottom
      )
      .ignoresSafeArea(edges: .bottom)
      .allowsHitTesting(false)
    }
  }
  /// For a strip that scrolls sideways inside a tab. Every scrolling screen in a tab keeps room
  /// for the floating tab bar under its content; a sideways strip must not, or it grows a blank
  /// band underneath.
  func quadSidewaysScroll() -> some View {
    contentMargins(.bottom, 0, for: .scrollContent)
  }
  /// A flat white card with one soft shadow.
  func quadCard(radius: CGFloat = 24) -> some View {
    background(.white, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .shadow(color: Color(quad: 0x1F2937).opacity(0.07), radius: 11, y: 8)
      .shadow(color: Color(quad: 0x1F2937).opacity(0.05), radius: 1, y: 1)
  }
}

/// The white rounded box that every typed answer sits in.
struct QuadFieldBox: ViewModifier {
  var vertical: CGFloat = 14
  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 16).padding(.vertical, vertical)
      .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .strokeBorder(Color.quadInk.opacity(0.08)))
  }
}

/// One answer among several. The chosen ones are green.
struct QuadChoice: View {
  let title: String
  let selected: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if selected { Image(systemName: "checkmark").imageScale(.small) }
        Text(title)
      }
      .font(.subheadline.weight(.bold))
      .foregroundStyle(selected ? Color.quadGreenText : Color.quadInk)
      .padding(.horizontal, 14).frame(minHeight: 40)
      .background(selected ? Color.quadGreenTint : Color.white, in: Capsule())
      .overlay(
        Capsule().strokeBorder(
          selected ? Color.quadGreen.opacity(0.35) : Color.quadInk.opacity(0.08)))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}

/// A small pill of text, optionally with a symbol.
struct QuadChip: View {
  enum Kind { case plain, price, good, note, dark }
  let text: String
  var symbol: String?
  var kind = Kind.plain
  var body: some View {
    HStack(spacing: 4) {
      if let symbol { Image(systemName: symbol).imageScale(.small) }
      Text(text)
    }
    .font(.caption.weight(.bold))
    .foregroundStyle(foreground)
    .padding(.horizontal, 10).padding(.vertical, 5)
    .background(background, in: Capsule())
    .fixedSize(horizontal: true, vertical: false)
  }
  private var background: Color {
    switch kind {
    case .plain: return .quadWell
    case .price: return .quadOrange
    case .good: return .quadGreenTint
    case .note: return .quadOrangeTint
    case .dark: return .quadInk
    }
  }
  private var foreground: Color {
    switch kind {
    case .plain, .price: return .quadInk
    case .good: return .quadGreenText
    case .note: return .quadOrangeTintText
    case .dark: return .white
    }
  }
}

/// A person's initials on one of three tints. The same person always gets the same tint.
struct QuadAvatar: View {
  let name: String
  let id: String
  var size: CGFloat = 42
  private static let tints: [(Color, Color)] = [
    (.quadIndigoTint, .quadIndigoText), (.quadOrangeTint, .quadOrangeTintText),
    (.quadGreenTint, .quadGreenText),
  ]
  var body: some View {
    let tint = Self.tints[QuadFormat.tintIndex(for: id, count: Self.tints.count)]
    Text(QuadFormat.initials(name))
      .font(.system(size: size * 0.34, weight: .heavy))
      .foregroundStyle(tint.1)
      .frame(width: size, height: size)
      .background(tint.0, in: Circle())
      .accessibilityHidden(true)
  }
}

/// The app's mark: three white squares and one orange circle on indigo. The circle is the open
/// spot.
struct QuadLogo: View {
  var size: CGFloat = 34
  var body: some View {
    let cell = size * 0.31
    let gap = size * 0.065
    VStack(spacing: gap) {
      HStack(spacing: gap) {
        square(cell)
        square(cell)
      }
      HStack(spacing: gap) {
        square(cell)
        Circle().fill(Color.quadOrange).frame(width: cell, height: cell)
      }
    }
    .frame(width: size, height: size)
    .background(Color.quadIndigo, in: RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
    .accessibilityHidden(true)
  }
  private func square(_ side: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: side * 0.3, style: .continuous).fill(.white)
      .frame(width: side, height: side)
  }
}
