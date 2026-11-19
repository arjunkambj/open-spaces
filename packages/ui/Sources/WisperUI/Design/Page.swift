import SwiftUI

/// How wide the content column of a `Page` may get on a Mac.
public enum PageWidth: Sendable {
  /// Lists and forms.
  case regular
  /// Screens with a side column.
  case wide

  var points: CGFloat {
    switch self {
    case .regular: 780
    case .wide: 1080
    }
  }
}

/// The frame of every screen: title, optional subtitle, toolbar on the trailing side,
/// then the content in a scrolling column of a comfortable width.
///
///     Page(title: "Dictionary", subtitle: "Words Open Wisper should know.") {
///       Button("Add word") { ... }.buttonStyle(.wisper(.primary))
///     } content: {
///       CardList(words) { word in ListRow(word.text) }
///     }
///
/// On a Mac it matches the hub's content panel. On iPhone it reads as a large-title screen
/// and paints the page background. The content is at least as tall as the screen, so
/// `.frame(maxHeight: .infinity)` centres an empty state in the space that is left.
public struct Page<Toolbar: View, Content: View>: View {
  private let title: String
  private let subtitle: String?
  private let width: PageWidth
  private var onBack: (() -> Void)?
  private let toolbar: Toolbar
  private let content: Content

  @Environment(\.wisperIdiom) private var idiom

  public init(
    title: String,
    subtitle: String? = nil,
    width: PageWidth = .regular,
    @ViewBuilder toolbar: () -> Toolbar = { EmptyView() },
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.width = width
    self.toolbar = toolbar()
    self.content = content()
  }

  /// Shows a back button beside the title that calls `action`. For screens opened from a list.
  public func onBack(_ action: @escaping () -> Void) -> Page {
    var page = self
    page.onBack = action
    return page
  }

  public var body: some View {
    let phone = idiom == .phone
    GeometryReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: phone ? Wisper.Space.xl : 28) {
          header
          VStack(alignment: .leading, spacing: Wisper.Space.xl) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: phone ? .infinity : width.points, alignment: .leading)
        .padding(.horizontal, phone ? 20 : 40)
        .padding(.top, phone ? Wisper.Space.s : 36)
        .padding(.bottom, phone ? Wisper.Space.xl : 40)
        .frame(maxWidth: .infinity)
        .frame(minHeight: proxy.size.height, alignment: .top)
      }
    }
    .background {
      if phone { Wisper.Color.panel.ignoresSafeArea() }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: Wisper.Space.s) {
      if idiom == .phone, let onBack {
        IconButton("chevron.left", label: "Back", action: onBack)
          .padding(.leading, -10)
      }
      HStack(alignment: .center, spacing: Wisper.Space.m) {
        if idiom == .mac, let onBack {
          IconButton("chevron.left", label: "Back", action: onBack)
            .padding(.leading, -6)
        }
        Text(title)
          .wisperText(.pageTitle)
          .accessibilityAddTraits(.isHeader)
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: Wisper.Space.s) { toolbar }
      }
      if let subtitle {
        Text(subtitle).wisperText(.body, color: Wisper.Color.textSecondary)
      }
    }
  }
}
