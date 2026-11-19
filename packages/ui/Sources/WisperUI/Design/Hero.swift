import SwiftUI

/// A wide, dark card with a serif headline: the one loud thing on a page. Use it to
/// introduce a feature at the top of its screen. It looks the same in light and dark mode.
///
///     HeroCard("Teach it your words.", message: "Names and terms you add are spelled right.") {
///       Button("Add a word") { ... }.buttonStyle(.wisper(.primary))
///     }
///     .onDismiss { hideHero() }
///
/// Controls inside it are drawn for a dark background, so `.primary` is the light button.
public struct HeroCard<Content: View>: View {
  private let title: String
  private let message: String?
  private var onDismiss: (() -> Void)?
  private let content: Content

  @Environment(\.wisperIdiom) private var idiom

  public init(
    _ title: String,
    message: String? = nil,
    @ViewBuilder content: () -> Content = { EmptyView() }
  ) {
    self.title = title
    self.message = message
    self.content = content()
  }

  /// Shows a close button in the corner that calls `action`.
  public func onDismiss(_ action: @escaping () -> Void) -> HeroCard {
    var card = self
    card.onDismiss = action
    return card
  }

  public var body: some View {
    let phone = idiom == .phone
    let shape = RoundedRectangle(cornerRadius: Wisper.Radius.panel, style: .continuous)
    VStack(alignment: .leading, spacing: Wisper.Space.l) {
      VStack(alignment: .leading, spacing: Wisper.Space.s) {
        Text(title)
          .wisperText(.hero)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.trailing, onDismiss == nil ? 0 : Wisper.Space.xl)
        if let message {
          Text(message)
            .wisperText(.body, color: Wisper.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if Content.self != EmptyView.self {
        HStack(spacing: Wisper.Space.s) { content }
      }
    }
    .padding(phone ? 20 : 28)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background { HeroBackdrop() }
    .clipShape(shape)
    .overlay { shape.strokeBorder(Wisper.Color.border, lineWidth: Wisper.Stroke.hairline) }
    .overlay(alignment: .topTrailing) {
      if let onDismiss {
        IconButton("xmark", label: "Dismiss", action: onDismiss)
          .padding(Wisper.Space.s)
      }
    }
    .environment(\.colorScheme, .dark)
  }
}

/// The hero's own picture: a warm night gradient with two soft glows. Drawn in code.
private struct HeroBackdrop: View {
  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      let reach = max(size.height, size.width * 0.3)
      ZStack {
        LinearGradient(
          colors: [Self.ink, Self.moss],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        RadialGradient(
          colors: [Self.pine, Self.pine.opacity(0)],
          center: UnitPoint(x: 0.92, y: 0.05),
          startRadius: 0,
          endRadius: reach * 1.25
        )
        RadialGradient(
          colors: [Self.ember, Self.ember.opacity(0)],
          center: UnitPoint(x: 0.6, y: 1.25),
          startRadius: 0,
          endRadius: reach * 0.95
        )
      }
    }
    .accessibilityHidden(true)
  }

  private static let ink = ColorPair(light: 0x1B1A17, dark: 0x1B1A17).color
  private static let moss = ColorPair(light: 0x232A22, dark: 0x232A22).color
  private static let pine = ColorPair(
    light: .init(hex: 0x2F8F68, alpha: 0.62),
    dark: .init(hex: 0x2F8F68, alpha: 0.62)
  ).color
  private static let ember = ColorPair(
    light: .init(hex: 0xC98A4B, alpha: 0.5),
    dark: .init(hex: 0xC98A4B, alpha: 0.5)
  ).color
}
