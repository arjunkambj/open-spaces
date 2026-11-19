import SwiftUI
import WisperDomain
import WisperEngine

/// Writing style per kind of app. Reads `AppModel` from the environment.
public struct StyleScreen: View {
  @Environment(AppModel.self) private var model
  @Environment(\.wisperIdiom) private var idiom

  @State private var category: AppCategory
  /// The width the content has. Decides whether the three cards fit side by side.
  @State private var width: CGFloat = StyleScreen.rowBreakpoint

  /// The cards sit in a row from this content width up.
  private static let rowBreakpoint: CGFloat = 640

  public init() {
    self.init(category: .personalMessages)
  }

  /// Starts on a given tab, so snapshots can show it.
  init(category: AppCategory) {
    _category = State(initialValue: category)
  }

  public var body: some View {
    Page(title: "Style", subtitle: "Choose how your words are written in each kind of app.") {
      if model.isLoaded && !model.settings.smartFormatting {
        Banner(
          .warning,
          title: "Styles need Smart formatting",
          message:
            "Smart formatting is off, so your text is typed as it was heard. Turn it on in Settings to use a style."
        )
      }
      VStack(alignment: .leading, spacing: Wisper.Space.l) {
        if idiom == .phone {
          Tabs(selection: $category, options: AppCategory.allCases, style: .segmented) {
            StyleText.shortLabel($0)
          }
        } else {
          Tabs(selection: $category, options: AppCategory.allCases) { $0.label }
        }
        Label {
          Text(StyleText.apps(category))
            .wisperText(.body, color: Wisper.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: StyleText.symbol(category))
            .wisperText(.body, color: Wisper.Color.textSecondary)
            .accessibilityHidden(true)
        }
      }
      VStack(alignment: .leading, spacing: Wisper.Space.m) {
        cards
          .accessibilityElement(children: .contain)
          .accessibilityLabel("Style for \(category.label.lowercased())")
        Text("A style changes capital letters and punctuation. Your words stay the same.")
          .wisperText(.caption)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        width = $0
      }
    }
  }

  @ViewBuilder private var cards: some View {
    if idiom == .mac && width >= Self.rowBreakpoint {
      HStack(alignment: .top, spacing: Wisper.Space.l) {
        options(isCompact: false)
      }
      .fixedSize(horizontal: false, vertical: true)
    } else {
      VStack(spacing: Wisper.Space.m) {
        options(isCompact: true)
      }
    }
  }

  private func options(isCompact: Bool) -> some View {
    let selected = model.settings.style(for: category)
    let category = category
    return ForEach(WritingStyle.allCases, id: \.self) { style in
      StyleOptionCard(
        style: style,
        category: category,
        userName: model.settings.userName,
        isSelected: style == selected,
        isCompact: isCompact
      ) {
        model.update { $0.styles[category] = style }
      }
    }
  }
}

/// The words of the style screen.
enum StyleText {
  /// A tab title short enough for four tabs on an iPhone.
  static func shortLabel(_ category: AppCategory) -> String {
    switch category {
    case .personalMessages: "Personal"
    case .workMessages: "Work"
    case .email: "Email"
    case .other: "Other"
    }
  }

  /// Which apps count for a category, in one line.
  static func apps(_ category: AppCategory) -> String {
    switch category {
    case .personalMessages: "Messages, WhatsApp, Telegram, Signal and other chats with friends and family."
    case .workMessages: "Slack, Microsoft Teams, Discord and other chats with the people you work with."
    case .email: "Mail, Outlook, Gmail and other email apps and sites."
    case .other: "Everywhere else you type: notes, documents, search boxes and code."
    }
  }

  static func symbol(_ category: AppCategory) -> String {
    switch category {
    case .personalMessages: "bubble.left.and.bubble.right"
    case .workMessages: "number"
    case .email: "envelope"
    case .other: "doc.text"
    }
  }

  /// The first letter of a name, for a small round picture. "?" never shows: no name gives "Y" for "You".
  static func initial(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "Y"
  }

  /// The name shown as the writer of a sample message.
  static func writer(_ name: String) -> String {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "You" : name
  }
}
