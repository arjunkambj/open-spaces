import SwiftUI

extension Spaces {
  /// Named text styles. Apply one with `.spacesText(_:)`.
  public enum TextStyle: Sendable, CaseIterable {
    /// The big title at the top of a page.
    case pageTitle
    /// A larger headline, for the steps of first-run setup.
    case hero
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
    /// A small, quiet label above a group.
    case sectionLabel
    /// Fixed-width text: paths, commands, keys.
    case mono
    /// The label inside a key cap.
    case keyCap
  }
}

extension Spaces.TextStyle {
  struct Metrics {
    var size: CGFloat
    var weight: Font.Weight
    var design: Font.Design = .default
    var tracking: CGFloat = 0
    var lineSpacing: CGFloat = 0
  }

  func metrics(_ idiom: Spaces.Idiom) -> Metrics {
    let phone = idiom == .phone
    switch self {
    case .pageTitle:
      return Metrics(size: phone ? 32 : 26, weight: phone ? .bold : .semibold, tracking: -0.5)
    case .hero:
      return Metrics(size: phone ? 30 : 32, weight: phone ? .bold : .semibold, tracking: -0.7)
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
      return Metrics(size: phone ? 14 : 13, weight: .medium)
    case .mono:
      return Metrics(size: phone ? 14 : 13, weight: .regular, design: .monospaced)
    case .keyCap:
      return Metrics(size: phone ? 14 : 13, weight: .medium)
    }
  }

  /// The Dynamic Type style this one grows and shrinks with.
  var relativeTo: Font.TextStyle {
    switch self {
    case .pageTitle, .hero: .largeTitle
    case .cardTitle: .headline
    case .body, .bodyStrong: .body
    case .caption, .captionStrong, .sectionLabel, .mono, .keyCap: .footnote
    }
  }

  var defaultColor: SwiftUI.Color {
    switch self {
    case .caption, .sectionLabel: Spaces.Color.textSecondary
    default: Spaces.Color.textPrimary
    }
  }
}

private struct TextStyleModifier: ViewModifier {
  let style: Spaces.TextStyle
  let color: SwiftUI.Color?
  @Environment(\.spacesIdiom) private var idiom
  @ScaledMetric private var scale: CGFloat

  init(style: Spaces.TextStyle, color: SwiftUI.Color?) {
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
      .foregroundStyle(color ?? style.defaultColor)
  }
}

extension View {
  /// Applies a named text style: font, letter spacing and colour.
  ///
  /// Sizes follow the idiom (Mac or iPhone) and Dynamic Type.
  /// - color: replaces the style's own colour (secondary for captions and section labels, primary otherwise).
  public func spacesText(_ style: Spaces.TextStyle, color: SwiftUI.Color? = nil) -> some View {
    modifier(TextStyleModifier(style: style, color: color))
  }
}
