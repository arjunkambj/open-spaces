import Foundation
import WisperDomain

/// What may be saved as a snippet, and why not when it may not.
enum SnippetRules {
  /// A one-word trigger needs at least this many letters.
  static let shortestWord = 4

  enum Problem: Equatable {
    case emptyTrigger
    /// One short word, which would also turn up in ordinary speech.
    case tooShort
    /// Another snippet already uses this phrase. Holds its trigger as saved.
    case duplicate(String)
    case emptyExpansion

    var message: String {
      switch self {
      case .emptyTrigger: "Type the phrase you will say."
      case .tooShort:
        "Use two or more words, or one word of at least \(SnippetRules.shortestWord) letters. "
          + "A very short phrase would go off by accident."
      case .duplicate(let trigger): "“\(trigger)” already has a snippet."
      case .emptyExpansion: "Type the text to insert."
      }
    }
  }

  struct Check: Equatable {
    var trigger: Problem?
    var expansion: Problem?

    var isValid: Bool { trigger == nil && expansion == nil }
  }

  /// Checks a snippet before it is saved.
  /// - editing: the snippet being changed, which is not compared with itself.
  static func check(
    trigger: String,
    expansion: String,
    editing: Snippet.ID? = nil,
    in snippets: [Snippet]
  ) -> Check {
    var check = Check()
    let words = SpokenPhrase.words(trigger)
    let key = words.joined(separator: " ")
    if key.isEmpty {
      check.trigger = .emptyTrigger
    } else if words.count < 2, key.filter({ $0.isLetter || $0.isNumber }).count < shortestWord {
      check.trigger = .tooShort
    } else if let twin = snippets.first(where: { $0.id != editing && SpokenPhrase.key($0.trigger) == key }) {
      check.trigger = .duplicate(twin.trigger)
    }
    if expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      check.expansion = .emptyExpansion
    }
    return check
  }

  /// The snippet to save for what was typed. Keeps the identity and date of `original` when editing.
  static func snippet(trigger: String, expansion: String, replacing original: Snippet? = nil) -> Snippet {
    Snippet(
      id: original?.id ?? UUID(),
      trigger: SpokenPhrase.tidy(trigger),
      expansion: expansion.trimmingCharacters(in: .whitespacesAndNewlines),
      createdAt: original?.createdAt ?? Date()
    )
  }

  /// The expansion on one line, for a list row: line breaks and runs of spaces become one space.
  static func preview(_ expansion: String) -> String {
    SpokenPhrase.tidy(expansion)
  }

  /// The snippets that match what was typed in the search field, in the trigger or the text.
  static func filter(_ snippets: [Snippet], query: String) -> [Snippet] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return snippets }
    return snippets.filter { contains($0.trigger, needle) || contains($0.expansion, needle) }
  }

  /// "1 snippet", "12 snippets".
  static func count(_ count: Int) -> String {
    count == 1 ? "1 snippet" : "\(count) snippets"
  }

  private static func contains(_ text: String, _ needle: String) -> Bool {
    text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }
}

/// Example snippets for an empty list. Picking one opens the dialog filled in, ready to change.
struct SnippetSample: Identifiable, Equatable {
  var id: String { title }
  /// The kind of snippet, shown on its chip.
  var title: String
  var trigger: String
  var expansion: String

  static func all(userName: String) -> [SnippetSample] {
    let name = SpokenPhrase.tidy(userName)
    return [
      SnippetSample(
        title: "Calendar link",
        trigger: "my calendar link",
        expansion: "https://cal.example.com/your-name"
      ),
      SnippetSample(
        title: "Email sign-off",
        trigger: "my sign off",
        expansion: "Thanks,\n\(name.isEmpty ? "Your name" : name)"
      ),
      SnippetSample(
        title: "Address",
        trigger: "my address",
        expansion: "42 Orchard Lane\nRivertown 10021"
      ),
    ]
  }
}
