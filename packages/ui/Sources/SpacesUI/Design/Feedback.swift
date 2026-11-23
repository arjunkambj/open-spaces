import SwiftUI

/// What to show when a list has nothing in it yet: a picture, a title, a sentence, an action.
///
///     EmptyState("No snippets yet", message: "Save text you type often.") {
///       SymbolTile("text.quote")
///     } action: {
///       Button("Add snippet") { ... }.buttonStyle(.spaces(.tertiary))
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
    VStack(spacing: Spaces.Space.l) {
      illustration
        .accessibilityHidden(true)
      VStack(spacing: Spaces.Space.s) {
        Text(title).spacesText(.cardTitle)
        if let message {
          Text(message)
            .spacesText(.body, color: Spaces.Color.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      action
        .padding(.top, Spaces.Space.xs)
    }
    .frame(maxWidth: 380)
    .padding(.vertical, Spaces.Space.xxl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// A simple illustration: one SF Symbol, drawn quietly with no box around it. For empty
/// states and the icons at the start of rows.
public struct SymbolTile: View {
  private let systemName: String
  private let size: CGFloat
  private let tint: SwiftUI.Color

  /// - size: how big it is, in points: 64 suits an empty state, 36 a row. The symbol is drawn
  ///   at half of it, in a frame a little larger, so symbols of different shapes line up.
  public init(_ systemName: String, size: CGFloat = 64, tint: SwiftUI.Color = Spaces.Color.textSecondary) {
    self.systemName = systemName
    self.size = size
    self.tint = tint
  }

  public var body: some View {
    Image(systemName: systemName)
      .font(.system(size: size * 0.5, weight: .regular))
      .foregroundStyle(tint)
      .frame(width: size * 0.625, height: size * 0.625)
      .accessibilityHidden(true)
  }
}

/// A thin bar that fills from left to right.
public struct ProgressBar: View {
  private let value: Double
  private let tint: SwiftUI.Color

  /// - value: from 0 to 1.
  public init(value: Double, tint: SwiftUI.Color = Spaces.Color.accent) {
    self.value = min(max(value, 0), 1)
    self.tint = tint
  }

  public var body: some View {
    GeometryReader { proxy in
      Capsule()
        .fill(Spaces.Color.surfaceSelected)
        .overlay(alignment: .leading) {
          Capsule()
            .fill(tint)
            .frame(width: max(proxy.size.height, proxy.size.width * value))
            .opacity(value > 0 ? 1 : 0)
        }
    }
    .frame(height: 6)
    .animation(Spaces.Motion.smooth, value: value)
    .accessibilityElement()
    .accessibilityLabel("Progress")
    .accessibilityValue("\(Int((value * 100).rounded())) percent")
  }
}

/// The mood of a `Banner` or a toast.
public enum NoticeTone: Sendable, Equatable {
  case info, success, warning, error

  /// Ink for every tone but `error`, which is red. The symbol tells the tones apart.
  var color: SwiftUI.Color {
    switch self {
    case .info: Spaces.Color.textPrimary
    case .success: Spaces.Color.success
    case .warning: Spaces.Color.warning
    case .error: Spaces.Color.danger
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
///       Button("Add key") { ... }.buttonStyle(.spaces(.tertiary, size: .small))
///     }
public struct Banner<Action: View>: View {
  private let tone: NoticeTone
  private let title: String
  private let message: String?
  private let action: Action

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
    let shape = RoundedRectangle(cornerRadius: Spaces.Radius.card, style: .continuous)
    HStack(alignment: .center, spacing: Spaces.Space.l) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Image(systemName: tone.symbol)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(tone.color)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Spaces.Space.xxs) {
          Text(title).spacesText(.bodyStrong)
          if let message {
            Text(message)
              .spacesText(.caption)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      action
    }
    .padding(.horizontal, Spaces.Space.l + Spaces.Space.xs)
    .padding(.vertical, Spaces.Space.l)
    .background(fill, in: shape)
    .accessibilityElement(children: .contain)
  }

  /// The fill alone sets a banner apart; there is no border. Grey, or a faint red for an error.
  private var fill: SwiftUI.Color {
    tone == .error ? Spaces.Color.danger.opacity(0.08) : Spaces.Color.surface
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
    HStack(spacing: Spaces.Space.s) {
      icon
        .font(.system(size: 14, weight: .medium))
        .accessibilityHidden(true)
      Text(toast.message)
        .spacesText(.captionStrong, color: Spaces.Color.onInverse)
        .lineLimit(2)
    }
    .padding(.horizontal, Spaces.Space.l + Spaces.Space.xs)
    .padding(.vertical, Spaces.Space.m)
    .background {
      Capsule().fill(Spaces.Color.inverse).shadow(color: .black.opacity(0.14), radius: 16, y: 6)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var icon: some View {
    if toast.tone != .error {
      Image(systemName: toast.tone.symbol).foregroundStyle(Spaces.Color.onInverse)
    } else {
      Image(systemName: toast.tone.symbol)
        .foregroundStyle(toast.tone.color)
        .environment(\.colorScheme, flipped)
    }
  }

  @Environment(\.colorScheme) private var scheme
  /// The capsule is dark in light mode and light in dark mode, so the red must flip too.
  private var flipped: ColorScheme { scheme == .dark ? .light : .dark }
}

private struct ToastModifier: ViewModifier {
  @Binding var toast: Toast?

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if let toast {
          ToastView(toast: toast)
            .padding(.bottom, Spaces.Space.xl)
            .padding(.horizontal, Spaces.Space.l)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(Spaces.Motion.spring, value: toast)
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
