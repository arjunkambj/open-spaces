import SwiftUI

/// A small, quiet label above a group of rows or cards.
public struct SectionLabel: View {
  private let text: String

  public init(_ text: String) {
    self.text = text
  }

  public var body: some View {
    Text(text)
      .spacesText(.sectionLabel)
      .accessibilityAddTraits(.isHeader)
  }
}

/// A group on a page: a section label, an optional control beside it, then the content.
///
///     PageSection("Today's dictations") {
///       CardList(dictations) { ... }
///     } trailing: {
///       SearchField(text: $query)
///     }
public struct PageSection<Content: View, Trailing: View>: View {
  private let title: String
  private let content: Content
  private let trailing: Trailing

  public init(
    _ title: String,
    @ViewBuilder content: () -> Content,
    @ViewBuilder trailing: () -> Trailing = { EmptyView() }
  ) {
    self.title = title
    self.content = content()
    self.trailing = trailing()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: Spaces.Space.s) {
        SectionLabel(title)
        Spacer(minLength: 0)
        trailing
      }
      .frame(minHeight: Trailing.self == EmptyView.self ? nil : 32)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A hairline divider.
public struct Hairline: View {
  public init() {}

  public var body: some View {
    Rectangle()
      .fill(Spaces.Color.border)
      .frame(height: Spaces.Stroke.hairline)
      .accessibilityHidden(true)
  }
}

/// How a `Card` or `CardList` is drawn.
public enum CardStyle: Sendable {
  /// No box at all: rows sit on the page with hairlines between them. For lists of content.
  case plain
  /// A warm-grey fill, no border. For groups of settings and things that are live.
  case filled
  /// A hairline border, no fill. For one thing set apart on a page.
  case outlined
}

/// How the rows of a list sit in it. `CardList` sets it; rows read it to pick their side
/// inset and the shape of their hover fill.
enum RowSetting: Sendable {
  /// On the page: no side inset, and a rounded hover fill that reaches into the page margin.
  case open
  /// In a box: inset from its edges, with a hover fill from edge to edge.
  case boxed
}

private struct RowSettingKey: EnvironmentKey {
  static let defaultValue = RowSetting.boxed
}

extension EnvironmentValues {
  var rowSetting: RowSetting {
    get { self[RowSettingKey.self] }
    set { self[RowSettingKey.self] = newValue }
  }
}

/// The side inset and the hover fill of a row, to suit the list it is in.
private struct RowChrome: ViewModifier {
  let isHighlighted: Bool
  @Environment(\.rowSetting) private var setting

  func body(content: Content) -> some View {
    let open = setting == .open
    content
      .padding(.horizontal, open ? 0 : Spaces.Space.l)
      .background {
        if isHighlighted {
          if open {
            RoundedRectangle(cornerRadius: Spaces.Radius.control, style: .continuous)
              .fill(Spaces.Color.surfaceHover)
              .padding(.horizontal, -RowMetrics.reach)
          } else {
            Spaces.Color.surfaceHover
          }
        }
      }
  }
}

enum RowMetrics {
  /// How far the hover fill of an open row reaches into the page margin on each side.
  static let reach = Spaces.Space.m
}

extension View {
  /// Gives a row you draw yourself the side inset and hover fill of the kit's own rows.
  /// Put it after the row's vertical padding, so the fill covers that too.
  func rowChrome(isHighlighted: Bool) -> some View {
    modifier(RowChrome(isHighlighted: isHighlighted))
  }
}

/// A rounded container for a group of content: a warm-grey fill, or just an outline.
public struct Card<Content: View>: View {
  private let style: CardStyle
  private let padding: CGFloat
  private let content: Content

  /// - padding: space inside the card. Use `0` when the card holds rows, which bring their own.
  public init(_ style: CardStyle = .filled, padding: CGFloat = 20, @ViewBuilder content: () -> Content) {
    self.style = style
    self.padding = padding
    self.content = content()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardBox(style)
  }
}

extension View {
  /// The fill, border and clipping of a card style. A plain one is left as it is.
  @ViewBuilder fileprivate func cardBox(_ style: CardStyle) -> some View {
    let shape = RoundedRectangle(cornerRadius: Spaces.Radius.card, style: .continuous)
    switch style {
    case .plain:
      self
    case .filled:
      background(Spaces.Color.surface, in: shape).clipShape(shape)
    case .outlined:
      clipShape(shape)
        .overlay { shape.strokeBorder(Spaces.Color.border, lineWidth: Spaces.Stroke.hairline) }
    }
  }
}

/// One row per item, with hairlines between them. Plain by default: the rows sit on the
/// page. Give it `.filled` for a short group that reads as one block, such as a menu of places.
///
///     CardList(model.words) { word in
///       ListRow(word.text)
///     }
public struct CardList<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
  private let data: Data
  private let style: CardStyle
  private let row: (Data.Element) -> Row

  public init(
    _ data: Data,
    style: CardStyle = .plain,
    @ViewBuilder row: @escaping (Data.Element) -> Row
  ) {
    self.data = data
    self.style = style
    self.row = row
  }

  public var body: some View {
    let last = data.last?.id
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(data) { item in
        row(item)
        if item.id != last { Hairline() }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .environment(\.rowSetting, style == .plain ? .open : .boxed)
    .cardBox(style)
  }
}

/// One row of a list: something leading, a title, a subtitle, something trailing, and
/// actions that show while the pointer is over the row or the keyboard is on it or on one
/// of them (always, on iPhone).
///
///     ListRow(dictation.text) {
///       Text(time).spacesText(.caption, color: Spaces.Color.textTertiary)
///     } hoverActions: {
///       IconButton("doc.on.doc", label: "Copy") { copy(dictation) }
///     }
///     .onTap { open(dictation) }
///     .lineLimit(1)
///
/// `.lineLimit(1)` keeps long text on one line. `.onTap` must come before other modifiers.
public struct ListRow<Leading: View, Trailing: View, HoverActions: View>: View {
  private let title: String
  private let subtitle: String?
  private var action: (() -> Void)?
  private let leading: Leading
  private let trailing: Trailing
  private let hoverActions: HoverActions

  @Environment(\.spacesIdiom) private var idiom
  @Environment(\.simulatedHover) private var simulatedHover
  /// Whether the keyboard is on the row itself, when the caller made the row focusable.
  @Environment(\.isFocused) private var rowIsFocused
  @State private var isHovered = false
  /// Whether the keyboard is on one of the actions.
  @FocusState private var actionIsFocused: Bool

  public init(
    _ title: String,
    subtitle: String? = nil,
    @ViewBuilder leading: () -> Leading = { EmptyView() },
    @ViewBuilder trailing: () -> Trailing = { EmptyView() },
    @ViewBuilder hoverActions: () -> HoverActions = { EmptyView() }
  ) {
    self.title = title
    self.subtitle = subtitle
    self.leading = leading()
    self.trailing = trailing()
    self.hoverActions = hoverActions()
  }

  /// Makes the whole row a button that runs `action`. Buttons inside the row keep working.
  public func onTap(_ action: @escaping () -> Void) -> ListRow {
    var row = self
    row.action = action
    return row
  }

  public var body: some View {
    let hovered = isHovered || simulatedHover
    HStack(spacing: Spaces.Space.m) {
      leading
      VStack(alignment: .leading, spacing: Spaces.Space.xxs) {
        Text(title).spacesText(.body)
        if let subtitle {
          Text(subtitle).spacesText(.caption)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      trailing
      if HoverActions.self != EmptyView.self {
        // Tab reaches the actions even while they are unseen, so they show for the keyboard too.
        HStack(spacing: Spaces.Space.xxs) { hoverActions }
          .focused($actionIsFocused)
          .opacity(idiom == .phone || hovered || rowIsFocused || actionIsFocused ? 1 : 0)
      }
    }
    .padding(.vertical, Spaces.Space.m)
    .frame(minHeight: idiom == .phone ? 56 : 52)
    .rowChrome(isHighlighted: hovered && action != nil)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(Spaces.Motion.quick, value: isHovered)
    .animation(Spaces.Motion.quick, value: rowIsFocused || actionIsFocused)
    .modifier(RowAction(action: action))
  }
}

/// Makes a row act as a button without swallowing the buttons inside it.
private struct RowAction: ViewModifier {
  let action: (() -> Void)?

  func body(content: Content) -> some View {
    if let action {
      content
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
    } else {
      content
    }
  }
}
