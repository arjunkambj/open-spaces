import SwiftUI

/// The Spaces mark: the space bar, speaking. A solid capsule, twice as wide as it is tall,
/// with three voice bars cut out of it, short, tall, short. Drawn in code; the app icon
/// (`scripts/make-icon.swift`) draws the same mark.
public struct SpacesGlyph: View {
  private let size: CGFloat
  private let tint: SwiftUI.Color

  /// - size: the height of the mark, in points. The mark is twice as wide as it is tall.
  /// - tint: the colour of the capsule. The bars are cut out, so what is behind shows through.
  public init(size: CGFloat = 20, tint: SwiftUI.Color = Spaces.Color.textPrimary) {
    self.size = size
    self.tint = tint
  }

  public var body: some View {
    SpacesMarkShape()
      .fill(tint, style: FillStyle(eoFill: true))
      .frame(width: size * SpacesMark.width, height: size)
      .accessibilityHidden(true)
  }
}

/// The sizes of the mark, as shares of its height.
private enum SpacesMark {
  /// How wide the capsule is.
  static let width: CGFloat = 2
  /// The thickness of a bar.
  static let bar: CGFloat = 0.16
  /// From the middle of one bar to the middle of the next.
  static let step: CGFloat = 0.3
  /// The length of the two outer bars, and of the middle one.
  static let short: CGFloat = 0.3
  static let tall: CGFloat = 0.58
}

/// The capsule with the three bars as holes in it. Fill it with the even-odd rule.
/// A plain path, so it is not flipped where text runs right to left.
private struct SpacesMarkShape: Shape {
  func path(in rect: CGRect) -> Path {
    let size = rect.height
    var path = Path(roundedRect: rect, cornerRadius: size / 2, style: .continuous)
    let bar = size * SpacesMark.bar
    for (offset, length) in [(-1.0, SpacesMark.short), (0, SpacesMark.tall), (1, SpacesMark.short)] {
      let middle = rect.midX + CGFloat(offset) * size * SpacesMark.step
      path.addRoundedRect(
        in: CGRect(x: middle - bar / 2, y: rect.midY - size * length / 2, width: bar, height: size * length),
        cornerSize: CGSize(width: bar / 2, height: bar / 2)
      )
    }
    return path
  }
}

/// The logo lockup: the mark and the name "Spaces".
public struct Wordmark: View {
  private let size: CGFloat

  /// - size: the overall height, in points. The name and the mark scale with it.
  public init(size: CGFloat = 20) {
    self.size = size
  }

  public var body: some View {
    HStack(spacing: size * 0.36) {
      SpacesGlyph(size: size * 0.7, tint: Spaces.Color.textPrimary)
      Text("Spaces")
        .font(.system(size: size * 0.9, weight: .semibold))
        .tracking(-size * 0.018)
        .foregroundStyle(Spaces.Color.textPrimary)
        .lineLimit(1)
        .fixedSize()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Spaces")
  }
}
