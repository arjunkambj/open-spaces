import SwiftUI

/// A small uppercase label above a group of rows or cards.
public struct SectionLabel: View {
  private let text: String

  public init(_ text: String) {
    self.text = text
  }

  public var body: some View {
    Text(text)
      .wisperText(.sectionLabel)
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
    VStack(alignment: .leading, spacing: Wisper.Space.m) {
      HStack(spacing: Wisper.Space.s) {
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
      .fill(Wisper.Color.border)
      .frame(height: Wisper.Stroke.hairline)
      .accessibilityHidden(true)
  }
}

/// How a `Card` or `CardList` is drawn.
public enum CardStyle: Sendable {
  /// Warm-grey fill with a hairline border. For settings groups and stat panels.
  case filled
  /// No fill, hairline border. For long lists of rows.
  case outlined
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
    let shape = RoundedRectangle(cornerRadius: Wisper.Radius.card, style: .continuous)
    VStack(alignment: .leading, spacing: 0) { content }
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(style == .filled ? Wisper.Color.surface : .clear, in: shape)
      .clipShape(shape)
      .overlay { shape.strokeBorder(Wisper.Color.border, lineWidth: Wisper.Stroke.hairline) }
  }
}

/// A card that holds one row per item, with hairlines between them.
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
    style: CardStyle = .outlined,
    @ViewBuilder row: @escaping (Data.Element) -> Row
  ) {
    self.data = data
    self.style = style
    self.row = row
  }

  public var body: some View {
    let last = data.last?.id
    let shape = RoundedRectangle(cornerRadius: Wisper.Radius.card, style: .continuous)
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(data) { item in
        row(item)
        if item.id != last { Hairline() }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(style == .filled ? Wisper.Color.surface : .clear, in: shape)
    .clipShape(shape)
    .overlay { shape.strokeBorder(Wisper.Color.border, lineWidth: Wisper.Stroke.hairline) }
  }
}

/// One row of a list: something leading, a title, a subtitle, something trailing, and
/// actions that show while the pointer is over the row (always, on iPhone).
///
///     ListRow(dictation.text) {
///       Text(time).wisperText(.caption, color: Wisper.Color.textTertiary)
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

  @Environment(\.wisperIdiom) private var idiom
  @Environment(\.simulatedHover) private var simulatedHover
  @State private var isHovered = false

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
    HStack(spacing: Wisper.Space.m) {
      leading
      VStack(alignment: .leading, spacing: Wisper.Space.xxs) {
        Text(title).wisperText(.body)
        if let subtitle {
          Text(subtitle).wisperText(.caption)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      trailing
      if HoverActions.self != EmptyView.self {
        HStack(spacing: Wisper.Space.xxs) { hoverActions }
          .opacity(idiom == .phone || hovered ? 1 : 0)
      }
    }
    .padding(.horizontal, Wisper.Space.l)
    .padding(.vertical, Wisper.Space.m)
    .frame(minHeight: idiom == .phone ? 56 : 52)
    .background(hovered && action != nil ? Wisper.Color.surfaceHover : .clear)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(Wisper.Motion.quick, value: isHovered)
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
