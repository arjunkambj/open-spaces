import SwiftUI

/// The Spaces mark: a sound wave that is also a small "w", in front of a text cursor.
/// What you say, written where you are typing. Drawn in code; the app icon
/// (`scripts/make-icon.swift`) draws the same mark.
public struct SpacesGlyph: View {
  private let size: CGFloat
  private let tint: SwiftUI.Color
  private let cursorTint: SwiftUI.Color

  /// - size: the height of the mark, in points. The mark is about a third wider than it is tall.
  /// - tint: the colour of the whole mark.
  public init(size: CGFloat = 20, tint: SwiftUI.Color = Spaces.Color.textPrimary) {
    self.init(size: size, tint: tint, cursorTint: tint)
  }

  /// The mark with its cursor in a colour of its own, as the logo has it.
  init(size: CGFloat, tint: SwiftUI.Color, cursorTint: SwiftUI.Color) {
    self.size = size
    self.tint = tint
    self.cursorTint = cursorTint
  }

  public var body: some View {
    ZStack {
      SpacesMarkWave()
        .stroke(
          tint,
          style: StrokeStyle(lineWidth: size * SpacesMark.stroke, lineCap: .round, lineJoin: .round)
        )
      SpacesMarkCursor().fill(cursorTint)
    }
    .frame(width: size * SpacesMark.width, height: size)
    .accessibilityHidden(true)
  }
}

/// The sizes of the mark, as shares of its height. The cursor is as tall as the mark.
private enum SpacesMark {
  /// The thickness of the wave.
  static let stroke: CGFloat = 0.135
  /// How far the wave moves sideways from one turn to the next.
  static let step: CGFloat = 0.22
  /// How far it moves up or down between turns.
  static let rise: CGFloat = 0.58
  /// How round its turns are.
  static let corner: CGFloat = 0.09
  /// How far the wave sits below the middle of the cursor, the way a small letter does in a line of text.
  static let drop: CGFloat = 0.03
  /// The space between the wave and the cursor.
  static let gap: CGFloat = 0.15
  static let cursor: CGFloat = 0.12
  static let width: CGFloat = 4 * step + stroke + gap + cursor
}

/// The wave: down, up, down, up. Two dips, so it is also a "w". Stroked by the caller.
/// A plain path, so it is not flipped where text runs right to left.
private struct SpacesMarkWave: Shape {
  func path(in rect: CGRect) -> Path {
    let size = rect.height
    let left = rect.minX + size * SpacesMark.stroke / 2
    let top = rect.midY + size * (SpacesMark.drop - SpacesMark.rise / 2)
    let bottom = rect.midY + size * (SpacesMark.drop + SpacesMark.rise / 2)
    let step = size * SpacesMark.step
    let turns = (0...4).map { index in
      CGPoint(x: left + CGFloat(index) * step, y: index.isMultiple(of: 2) ? top : bottom)
    }
    var path = Path()
    path.move(to: turns[0])
    for index in 1..<4 {
      path.addArc(tangent1End: turns[index], tangent2End: turns[index + 1], radius: size * SpacesMark.corner)
    }
    path.addLine(to: turns[4])
    return path
  }
}

/// The text cursor at the right of the mark.
private struct SpacesMarkCursor: Shape {
  func path(in rect: CGRect) -> Path {
    let width = rect.height * SpacesMark.cursor
    return Path(
      roundedRect: CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height),
      cornerRadius: width / 2
    )
  }
}

/// The logo lockup: the mark and the name "Spaces".
public struct Wordmark: View {
  private let size: CGFloat

  /// - size: the height of the mark, in points. The name scales with it.
  public init(size: CGFloat = 20) {
    self.size = size
  }

  public var body: some View {
    HStack(spacing: size * 0.42) {
      SpacesGlyph(size: size, tint: Spaces.Color.textPrimary, cursorTint: Spaces.Color.accent)
      Text("Spaces")
        // Rounded letters, to go with the rounded line of the mark. The one place they are used.
        .font(.system(size: size * 0.9, weight: .semibold, design: .rounded))
        .tracking(-size * 0.015)
        .foregroundStyle(Spaces.Color.textPrimary)
        .lineLimit(1)
        .fixedSize()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Spaces")
  }
}
