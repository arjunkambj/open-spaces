import Foundation
import SpacesDomain

/// How a spoken phrase is compared: the way dictation matches it against what was heard.
enum SpokenPhrase {
  /// Punctuation a sentence puts around a phrase.
  private static let wrapping = CharacterSet.whitespacesAndNewlines
    .union(CharacterSet(charactersIn: ".,;:!?…\"“”'‘’()[]"))

  /// The lower-cased words of a phrase. Spaces and hyphens both separate words.
  static func words(_ phrase: String) -> [String] {
    phrase
      .trimmingCharacters(in: wrapping)
      .lowercased()
      .replacingOccurrences(of: "’", with: "'")
      .split { $0.isWhitespace || $0 == "-" }
      .map(String.init)
  }

  /// Two phrases with the same key are heard as the same thing.
  static func key(_ phrase: String) -> String {
    words(phrase).joined(separator: " ")
  }

  /// A phrase as it is stored: no space at the ends, one space between words, no line breaks.
  static func tidy(_ phrase: String) -> String {
    phrase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}

/// What may be saved to the dictionary, and why not when it may not.
enum DictionaryRules {
  enum Problem: Equatable {
    case empty
    /// The word is already there. Holds it as it is spelled in the dictionary.
    case duplicate(String)
    /// Another word already replaces this phrase. Holds that word.
    case heardAsTaken(by: String)

    var message: String {
      switch self {
      case .empty: "Type a word or name first."
      case .duplicate(let word): "“\(word)” is already in your dictionary."
      case .heardAsTaken(let word): "This is already replaced with “\(word)”."
      }
    }
  }

  struct Check: Equatable {
    var word: Problem?
    var heardAs: Problem?

    var isValid: Bool { word == nil && heardAs == nil }
  }

  /// Checks a word before it is saved.
  ///
  /// A word may be listed more than once only to give it another "heard as" phrase, because
  /// one word can be misheard in several ways.
  /// - editing: the entry being changed, which is not compared with itself.
  static func check(
    text: String,
    heardAs: String,
    editing: DictionaryWord.ID? = nil,
    in words: [DictionaryWord]
  ) -> Check {
    let text = SpokenPhrase.tidy(text)
    let heardKey = SpokenPhrase.key(heardAs)
    let others = words.filter { $0.id != editing }
    var check = Check()

    if text.isEmpty {
      check.word = .empty
    } else if let twin = others.first(where: { other in
      isSame(other.text, text) && (heardKey.isEmpty || SpokenPhrase.key(other.replaces ?? "") == heardKey)
    }) {
      check.word = .duplicate(twin.text)
    }

    if check.word == nil, !heardKey.isEmpty,
      let owner = others.first(where: { SpokenPhrase.key($0.replaces ?? "") == heardKey })
    {
      check.heardAs = .heardAsTaken(by: owner.text)
    }
    return check
  }

  /// The entry to save for what was typed. Keeps the identity and date of `original` when editing.
  static func word(text: String, heardAs: String, replacing original: DictionaryWord? = nil) -> DictionaryWord
  {
    let text = SpokenPhrase.tidy(text)
    let heardAs = SpokenPhrase.tidy(heardAs)
    // Replacing a word with itself does nothing.
    let isUseful = !SpokenPhrase.key(heardAs).isEmpty && heardAs != text
    return DictionaryWord(
      id: original?.id ?? UUID(),
      text: text,
      replaces: isUseful ? heardAs : nil,
      createdAt: original?.createdAt ?? Date()
    )
  }

  /// The words that match what was typed in the search field, in the word or its "heard as" phrase.
  static func filter(_ words: [DictionaryWord], query: String) -> [DictionaryWord] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return words }
    return words.filter { contains($0.text, needle) || contains($0.replaces ?? "", needle) }
  }

  /// "1 word", "12 words".
  static func count(_ count: Int) -> String {
    count == 1 ? "1 word" : "\(count) words"
  }

  private static func isSame(_ a: String, _ b: String) -> Bool {
    SpokenPhrase.tidy(a).compare(SpokenPhrase.tidy(b), options: .caseInsensitive) == .orderedSame
  }

  private static func contains(_ text: String, _ needle: String) -> Bool {
    text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }
}
