import SwiftUI

/// One key of the keyboard, as a small chip: "fn", "Space", "⌘".
public struct KeyCap: View {
  private let label: String
  @Environment(\.spacesIdiom) private var idiom

  public init(_ label: String) {
    self.label = label
  }

  public var body: some View {
    let side: CGFloat = idiom == .phone ? 28 : 24
    let shape = RoundedRectangle(cornerRadius: Spaces.Radius.small, style: .continuous)
    Text(label)
      .spacesText(.keyCap)
      .lineLimit(1)
      .padding(.horizontal, 7)
      .frame(minWidth: side, minHeight: side)
      .background(Spaces.Color.surfaceSelected, in: shape)
      .overlay { shape.strokeBorder(Spaces.Color.border, lineWidth: Spaces.Stroke.hairline) }
  }
}

/// A keyboard shortcut as a row of key caps. VoiceOver reads it as one item.
public struct KeyCapRow: View {
  private let labels: [String]

  /// - labels: one entry per key, in the order to press them, e.g. `["fn", "Space"]`.
  public init(_ labels: [String]) {
    self.labels = labels
  }

  public var body: some View {
    HStack(spacing: Spaces.Space.xs) {
      ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
        KeyCap(label)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(labels.joined(separator: " "))
  }
}
