import SwiftUI
import WisperDomain
import WisperEngine
import WisperUI

/// The Library tab: the short list that leads to the dictionary, the snippets, the writing
/// styles and the keyboard. Reads `AppModel` and `PhoneSession` from the environment, and
/// expects to sit in the `NavigationStack` that follows `PhoneSession.libraryPath`.
public struct LibraryScreen: View {
  @Environment(AppModel.self) private var model
  @Environment(PhoneSession.self) private var session

  public init() {}

  public var body: some View {
    Page(title: "Library", subtitle: "Teach Open Wisper your words, your shortcuts and your tone.") {
      CardList(PhoneSession.LibraryPage.allCases, style: .filled) { page in
        ListRow(
          page.title,
          subtitle: summary(of: page),
          leading: { SymbolTile(page.symbol, size: 36) },
          trailing: {
            Image(systemName: "chevron.right")
              .wisperText(.captionStrong, color: Wisper.Color.textTertiary)
              .accessibilityHidden(true)
          }
        )
        .onTap { session.libraryPath.append(page) }
      }
    }
  }

  /// The screen a row opens.
  @MainActor @ViewBuilder
  static func destination(_ page: PhoneSession.LibraryPage) -> some View {
    switch page {
    case .dictionary: DictionaryScreen()
    case .snippets: SnippetsScreen()
    case .style: StyleScreen()
    case .keyboard: KeyboardSetupScreen()
    }
  }

  private func summary(of page: PhoneSession.LibraryPage) -> String {
    switch page {
    case .dictionary:
      model.words.isEmpty ? "Names and words to spell your way" : Self.count(model.words.count, "word")
    case .snippets:
      model.snippets.isEmpty
        ? "Say a short phrase, get the full text" : Self.count(model.snippets.count, "snippet")
    case .style:
      "How formal your text reads"
    case .keyboard:
      "Dictate and paste from any app"
    }
  }

  private static func count(_ number: Int, _ noun: String) -> String {
    number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
  }
}

extension PhoneSession.LibraryPage {
  var title: String {
    switch self {
    case .dictionary: "Dictionary"
    case .snippets: "Snippets"
    case .style: "Style"
    case .keyboard: "Keyboard"
    }
  }

  var symbol: String {
    switch self {
    case .dictionary: "character.book.closed"
    case .snippets: "text.quote"
    case .style: "textformat"
    case .keyboard: "keyboard"
    }
  }
}
