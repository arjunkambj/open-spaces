import SwiftUI

/// What to show when a list has nothing in it yet: a picture, a title, a sentence, an action.
///
///     EmptyState("No snippets yet", message: "Save text you type often.") {
///       SymbolTile("text.quote")
///     } action: {
///       Button("Add snippet") { ... }.buttonStyle(.wisper(.tertiary))
///     }
public struct EmptyState<Illustration: View, Action: View>: View {
  private let title: String
  private let message: String?
  private let illustration: Illustration
  private let action: Action

  public init(
    _ title: String,
    message: String? = nil,
    @ViewBuilder illustration: () -> Illustration = { EmptyView() },
    @ViewBuilder action: () -> Action = { EmptyView() }
  ) {
    self.title = title
    self.message = message
    self.illustration = illustration()
    self.action = action()
  }

  public var body: some View {
    VStack(spacing: Wisper.Space.l) {
      illustration
        .accessibilityHidden(true)
      VStack(spacing: 6) {
        Text(title).wisperText(.cardTitle)
        if let message {
          Text(message)
            .wisperText(.body, color: Wisper.Color.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      action
        .padding(.top, Wisper.Space.xs)
    }
    .frame(maxWidth: 380)
    .padding(.vertical, Wisper.Space.xxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// A simple illustration: an SF Symbol on a soft rounded tile. For empty states and row icons.
public struct SymbolTile: View {
  private let systemName: String
  private let size: CGFloat
  private let tint: SwiftUI.Color

  /// - size: the side of the tile, in points. 64 suits an empty state, 36 a row.
  public init(_ systemName: String, size: CGFloat = 64, tint: SwiftUI.Color = Wisper.Color.textPrimary) {
    self.systemName = systemName
    self.size = size
    self.tint = tint
  }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
    Image(systemName: systemName)
      .font(.system(size: size * 0.42, weight: .regular))
      .foregroundStyle(tint)
      .frame(width: size, height: size)
      .background(Wisper.Color.surface, in: shape)
      .overlay { shape.strokeBorder(Wisper.Color.border, lineWidth: Wisper.Stroke.hairline) }
      .accessibilityHidden(true)
  }
}

/// A number worth showing off, in the serif face, with a plain label beside or under it.
public struct StatTile: View {
  public enum Layout: Sendable {
    /// Number, then the label on the same line.
    case inline
    /// Number above, label below.
    case stacked
  }

  private let value: String
  private let label: String
  private let layout: Layout

  /// - value: already formatted, e.g. "14.2K".
  public init(_ value: String, label: String, layout: Layout = .inline) {
    self.value = value
    self.label = label
    self.layout = layout
  }

  public var body: some View {
    Group {
      switch layout {
      case .inline:
        HStack(alignment: .firstTextBaseline, spacing: Wisper.Space.s) {
          Text(value).wisperText(.statNumber)
          Text(label).wisperText(.body)
        }
      case .stacked:
        VStack(alignment: .leading, spacing: Wisper.Space.xs) {
          Text(value).wisperText(.statNumber)
          Text(label).wisperText(.sectionLabel)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// A thin bar that fills from left to right.
public struct ProgressBar: View {
  private let value: Double
  private let tint: SwiftUI.Color

  /// - value: from 0 to 1.
  public init(value: Double, tint: SwiftUI.Color = Wisper.Color.accent) {
    self.value = min(max(value, 0), 1)
    self.tint = tint
  }

  public var body: some View {
    GeometryReader { proxy in
      Capsule()
        .fill(Wisper.Color.surfaceSelected)
        .overlay(alignment: .leading) {
          Capsule()
            .fill(tint)
            .frame(width: max(proxy.size.height, proxy.size.width * value))
            .opacity(value > 0 ? 1 : 0)
        }
    }
    .frame(height: 6)
    .animation(Wisper.Motion.smooth, value: value)
    .accessibilityElement()
    .accessibilityLabel("Progress")
    .accessibilityValue("\(Int((value * 100).rounded())) percent")
  }
}

/// The mood of a `Banner` or a toast.
public enum NoticeTone: Sendable, Equatable {
  case info, success, warning, error

  var color: SwiftUI.Color {
    switch self {
    case .info: Wisper.Color.accent
    case .success: Wisper.Color.success
    case .warning: Wisper.Color.warning
    case .error: Wisper.Color.danger
    }
  }

  var symbol: String {
    switch self {
    case .info: "info.circle.fill"
    case .success: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .error: "exclamationmark.octagon.fill"
    }
  }
}

/// A notice inside a page: an icon, a sentence or two, and an optional action.
///
///     Banner(.warning, title: "No API key", message: "Add your OpenAI key to start dictating.") {
///       Button("Add key") { ... }.buttonStyle(.wisper(.tertiary, size: .small))
///     }
public struct Banner<Action: View>: View {
  private let tone: NoticeTone
  private let title: String
  private let message: String?
  private let action: Action

  @Environment(\.wisperIdiom) private var idiom

  public init(
    _ tone: NoticeTone = .info,
    title: String,
    message: String? = nil,
    @ViewBuilder action: () -> Action = { EmptyView() }
  ) {
    self.tone = tone
    self.title = title
    self.message = message
    self.action = action()
  }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: Wisper.Radius.card, style: .continuous)
    let layout =
      idiom == .phone
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: Wisper.Space.m))
      : AnyLayout(HStackLayout(alignment: .center, spacing: Wisper.Space.l))
    layout {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: tone.symbol)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(tone.color)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Wisper.Space.xxs) {
          Text(title).wisperText(.bodyStrong)
          if let message {
            Text(message)
              .wisperText(.caption)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      action
    }
    .padding(.horizontal, Wisper.Space.l)
    .padding(.vertical, 14)
    .background(Wisper.Color.surface, in: shape)
    .background(tone.color.opacity(0.07), in: shape)
    .overlay { shape.strokeBorder(tone.color.opacity(0.28), lineWidth: Wisper.Stroke.hairline) }
    .accessibilityElement(children: .contain)
  }
}

/// A short message that appears at the bottom for a moment. Show one with `.toast(_:)`.
public struct Toast: Equatable, Sendable {
  public var message: String
  public var tone: NoticeTone

  public init(_ message: String, tone: NoticeTone = .success) {
    self.message = message
    self.tone = tone
  }
}

/// The dark capsule a toast is drawn in.
struct ToastView: View {
  let toast: Toast

  var body: some View {
    HStack(spacing: Wisper.Space.s) {
      icon
        .font(.system(size: 14, weight: .medium))
        .accessibilityHidden(true)
      Text(toast.message)
        .wisperText(.captionStrong, color: Wisper.Color.onInverse)
        .lineLimit(2)
    }
    .padding(.horizontal, Wisper.Space.l)
    .padding(.vertical, 10)
    .background {
      Capsule().fill(Wisper.Color.inverse).shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var icon: some View {
    if toast.tone == .info {
      Image(systemName: toast.tone.symbol).foregroundStyle(Wisper.Color.onInverse)
    } else {
      Image(systemName: toast.tone.symbol)
        .foregroundStyle(toast.tone.color)
        .environment(\.colorScheme, flipped)
    }
  }

  @Environment(\.colorScheme) private var scheme
  /// The capsule is dark in light mode and light in dark mode, so tone colours must flip too.
  private var flipped: ColorScheme { scheme == .dark ? .light : .dark }
}

private struct ToastModifier: ViewModifier {
  @Binding var toast: Toast?

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if let toast {
          ToastView(toast: toast)
            .padding(.bottom, Wisper.Space.xl)
            .padding(.horizontal, Wisper.Space.l)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(Wisper.Motion.spring, value: toast)
      .task(id: toast) {
        guard toast != nil else { return }
        try? await Task.sleep(for: .seconds(2.6))
        if !Task.isCancelled { toast = nil }
      }
  }
}

extension View {
  /// Shows a toast at the bottom of this view while the binding holds one, then clears it.
  public func toast(_ toast: Binding<Toast?>) -> some View {
    modifier(ToastModifier(toast: toast))
  }
}
