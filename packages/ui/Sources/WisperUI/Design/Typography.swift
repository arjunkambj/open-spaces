import SwiftUI

extension Wisper {
  /// Named text styles. Apply one with `.wisperText(_:)`.
  public enum TextStyle: Sendable, CaseIterable {
    /// The big title at the top of a page.
    case pageTitle
    /// A serif headline for hero areas and dialogs that deserve one.
    case hero
    /// A large serif numeral, for stats.
    case statNumber
    /// The title of a card or dialog.
    case cardTitle
    /// Normal reading text.
    case body
    /// Body text with weight: row titles that matter, button labels.
    case bodyStrong
    /// Helper text.
    case caption
    /// Small text with weight: field labels, small buttons, badges.
    case captionStrong
    /// A small uppercase label with letter spacing, above a group.
    case sectionLabel
    /// Fixed-width text: paths, commands, keys.
    case mono
    /// The label inside a key cap.
    case keyCap
  }
}

extension Wisper.TextStyle {
  struct Metrics {
    var size: CGFloat
    var weight: Font.Weight
    var design: Font.Design = .default
    var tracking: CGFloat = 0
    var lineSpacing: CGFloat = 0
    var uppercase = false
  }

  func metrics(_ idiom: Wisper.Idiom) -> Metrics {
    let phone = idiom == .phone
    switch self {
    case .pageTitle:
      return Metrics(size: phone ? 32 : 28, weight: phone ? .bold : .semibold, tracking: -0.5)
    case .hero:
      return Metrics(size: phone ? 30 : 32, weight: .regular, design: .serif, tracking: -0.6)
    case .statNumber:
      return Metrics(size: 30, weight: .regular, design: .serif, tracking: -0.4)
    case .cardTitle:
      return Metrics(size: phone ? 18 : 17, weight: .semibold, tracking: -0.2)
    case .body:
      return Metrics(size: phone ? 17 : 15, weight: .regular, lineSpacing: 3)
    case .bodyStrong:
      return Metrics(size: phone ? 17 : 15, weight: .medium, lineSpacing: 3)
    case .caption:
      return Metrics(size: phone ? 14 : 13, weight: .regular, lineSpacing: 2)
    case .captionStrong:
      return Metrics(size: phone ? 14 : 13, weight: .medium)
    case .sectionLabel:
      return Metrics(size: phone ? 13 : 12, weight: .medium, tracking: 1.3, uppercase: true)
    case .mono:
      return Metrics(size: phone ? 14 : 13, weight: .regular, design: .monospaced)
    case .keyCap:
      return Metrics(size: phone ? 14 : 13, weight: .medium)
    }
  }

  /// The Dynamic Type style this one grows and shrinks with.
  var relativeTo: Font.TextStyle {
    switch self {
    case .pageTitle, .hero, .statNumber: .largeTitle
    case .cardTitle: .headline
    case .body, .bodyStrong: .body
    case .caption, .captionStrong, .sectionLabel, .mono, .keyCap: .footnote
    }
  }

  var defaultColor: SwiftUI.Color {
    switch self {
    case .caption, .sectionLabel: Wisper.Color.textSecondary
    default: Wisper.Color.textPrimary
    }
  }
}

private struct TextStyleModifier: ViewModifier {
  let style: Wisper.TextStyle
  let color: SwiftUI.Color?
  @Environment(\.wisperIdiom) private var idiom
  @ScaledMetric private var scale: CGFloat

  init(style: Wisper.TextStyle, color: SwiftUI.Color?) {
    self.style = style
    self.color = color
    _scale = ScaledMetric(wrappedValue: 1, relativeTo: style.relativeTo)
  }

  func body(content: Content) -> some View {
    let metrics = style.metrics(idiom)
    content
      .font(.system(size: metrics.size * scale, weight: metrics.weight, design: metrics.design))
      .tracking(metrics.tracking)
      .lineSpacing(metrics.lineSpacing)
      .textCase(metrics.uppercase ? .uppercase : nil)
      .foregroundStyle(color ?? style.defaultColor)
  }
}

extension View {
  /// Applies a named text style: font, letter spacing, case and colour.
  ///
  /// Sizes follow the idiom (Mac or iPhone) and Dynamic Type.
  /// - color: replaces the style's own colour (secondary for captions and section labels, primary otherwise).
  public func wisperText(_ style: Wisper.TextStyle, color: SwiftUI.Color? = nil) -> some View {
    modifier(TextStyleModifier(style: style, color: color))
  }
}
