import SwiftUI

/// The Open Wisper mark: five rounded bars rising like a spoken word. Drawn in code.
public struct WisperGlyph: View {
  private let size: CGFloat
  private let tint: SwiftUI.Color

  /// - size: the height of the mark, in points.
  public init(size: CGFloat = 20, tint: SwiftUI.Color = Wisper.Color.textPrimary) {
    self.size = size
    self.tint = tint
  }

  /// The height of each bar as a share of the mark's height.
  private static let bars: [CGFloat] = [0.38, 0.72, 1, 0.56, 0.3]

  public var body: some View {
    let barWidth = size * 0.13
    HStack(alignment: .center, spacing: size * 0.09) {
      ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, share in
        Capsule()
          .fill(tint)
          .frame(width: barWidth, height: size * share)
      }
    }
    .frame(height: size)
    .accessibilityHidden(true)
  }
}

/// The logo lockup: the mark and the name "Open Wisper".
public struct Wordmark: View {
  private let size: CGFloat

  /// - size: the height of the mark, in points. The name scales with it.
  public init(size: CGFloat = 20) {
    self.size = size
  }

  public var body: some View {
    HStack(spacing: size * 0.4) {
      WisperGlyph(size: size)
      Text("Open Wisper")
        .font(.system(size: size * 0.9, weight: .semibold))
        .tracking(-size * 0.02)
        .foregroundStyle(Wisper.Color.textPrimary)
        .lineLimit(1)
        .fixedSize()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Open Wisper")
  }
}
