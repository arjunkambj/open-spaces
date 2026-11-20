import SwiftUI

/// What a list shows while the library is still being read. It stays blank for a moment,
/// so a fast load does not flash anything.
struct ScreenLoading: View {
  private let message: String
  @State private var isVisible = false

  init(_ message: String) {
    self.message = message
  }

  var body: some View {
    VStack(spacing: Spaces.Space.m) {
      ProcessingIndicator(tint: Spaces.Color.textTertiary)
      Text(message).spacesText(.caption)
    }
    .opacity(isVisible ? 1 : 0)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.vertical, Spaces.Space.xxxl)
    .accessibilityElement(children: .combine)
    .task {
      try? await Task.sleep(for: .milliseconds(400))
      withAnimation(Spaces.Motion.smooth) { isVisible = true }
    }
  }
}

/// A centred row of small items that wraps onto more lines when it runs out of width.
struct ChipRow<Data: RandomAccessCollection, Chip: View>: View where Data.Element: Identifiable {
  private let data: Data
  private let chip: (Data.Element) -> Chip

  init(_ data: Data, @ViewBuilder chip: @escaping (Data.Element) -> Chip) {
    self.data = data
    self.chip = chip
  }

  var body: some View {
    WrappingRow(spacing: Spaces.Space.s) {
      ForEach(data) { item in chip(item) }
    }
  }
}

/// Lays its children out in centred lines, starting a new line when one is full.
private struct WrappingRow: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let lines = lines(subviews, width: proposal.width ?? .infinity)
    let width = lines.map(\.width).max() ?? 0
    let height = lines.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(lines.count - 1, 0))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for line in lines(subviews, width: bounds.width) {
      var x = bounds.midX - line.width / 2
      for index in line.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(
          at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
          proposal: ProposedViewSize(size)
        )
        x += size.width + spacing
      }
      y += line.height + spacing
    }
  }

  private struct Line {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func lines(_ subviews: Subviews, width: CGFloat) -> [Line] {
    var lines: [Line] = []
    var line = Line()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let grown = line.indices.isEmpty ? size.width : line.width + spacing + size.width
      if grown > width, !line.indices.isEmpty {
        lines.append(line)
        line = Line(indices: [index], width: size.width, height: size.height)
      } else {
        line.indices.append(index)
        line.width = grown
        line.height = max(line.height, size.height)
      }
    }
    if !line.indices.isEmpty { lines.append(line) }
    return lines
  }
}

extension View {
  /// Lets a list row be used from the keyboard on a Mac: Tab reaches it, Return opens it
  /// and the Delete key asks to delete it.
  func rowKeys(open: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
    modifier(RowKeys(open: open, delete: delete))
  }
}

private struct RowKeys: ViewModifier {
  let open: () -> Void
  let delete: () -> Void

  @FocusState private var isFocused: Bool
  @Environment(\.rowSetting) private var setting

  func body(content: Content) -> some View {
    #if os(macOS)
      // Focus works as it does for a button: Tab reaches the row when the Mac's keyboard
      // navigation is on, and a click does not leave a focus mark behind. The mark is drawn
      // by us, because a boxed list clips what is outside the row.
      content
        .overlay {
          if isFocused {
            RoundedRectangle(cornerRadius: Spaces.Radius.control, style: .continuous)
              .strokeBorder(Spaces.Color.textPrimary, lineWidth: Spaces.Stroke.focus)
              // Inside a box the mark stays inside the row; on the page it sits where the hover fill does.
              .padding(.horizontal, setting == .open ? -RowMetrics.reach : Spaces.Space.xs)
              .padding(.vertical, setting == .open ? 0 : Spaces.Space.xs)
              .allowsHitTesting(false)
          }
        }
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.return, .space]) { _ in
          open()
          return .handled
        }
        .onDeleteCommand(perform: delete)
    #else
      content
    #endif
  }
}
