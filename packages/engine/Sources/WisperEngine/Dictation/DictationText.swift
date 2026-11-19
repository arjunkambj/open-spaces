import Foundation
import WisperDomain

/// Swaps whole phrases for their replacements, in one pass over the text.
///
/// Matching ignores case, treats any run of spaces or hyphens between the
/// words of a phrase as one gap, and never matches inside a longer word.
/// Replacements go in exactly as given. Dictionary corrections and snippets
/// both run on this.
struct PhraseReplacer: Sendable {
  private let pattern: String?
  private let replacements: [String: String]

  /// When two pairs share a phrase, the first one wins.
  init(_ pairs: [(phrase: String, replacement: String)]) {
    var table: [String: String] = [:]
    var patterns: [(key: String, pattern: String)] = []
    for pair in pairs {
      let words = Self.words(pair.phrase)
      let key = words.joined(separator: " ")
      guard !words.isEmpty, table[key] == nil else { continue }
      table[key] = pair.replacement
      let pattern = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: #"[\s\-]+"#)
      // Speech-to-text writes either kind of apostrophe.
      patterns.append((key, pattern.replacingOccurrences(of: "'", with: "['’]")))
    }
    // Longest first, so "post gres q l" wins over "post gres" where both could match.
    patterns.sort { $0.key.count > $1.key.count }
    replacements = table
    pattern =
      patterns.isEmpty
      ? nil
      : #"(?<![\p{L}\p{N}])(?:"# + patterns.map(\.pattern).joined(separator: "|") + #")(?![\p{L}\p{N}])"#
  }

  /// `text` with every phrase swapped for its replacement.
  func apply(to text: String) -> String {
    let source = text as NSString
    var result = ""
    var cursor = 0
    for range in matches(in: text) {
      guard let replacement = replacements[Self.key(source.substring(with: range))] else { continue }
      result += source.substring(with: NSRange(location: cursor, length: range.location - cursor))
      result += replacement
      cursor = range.location + range.length
    }
    return result + source.substring(from: cursor)
  }

  /// The replacement when `text` is one phrase and nothing else (punctuation around it is ignored).
  func whole(_ text: String) -> String? {
    replacements[Self.key(text)]
  }

  /// The phrases that occur in `text`, as they appear there.
  func found(in text: String) -> [String] {
    let source = text as NSString
    return matches(in: text).map { source.substring(with: $0) }
  }

  private func matches(in text: String) -> [NSRange] {
    guard let pattern, let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return [] }
    return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(
      \.range
    )
  }

  private static func key(_ text: String) -> String {
    words(text).joined(separator: " ")
  }

  /// Punctuation a sentence puts around a phrase. Narrow on purpose, so a
  /// phrase such as "C#" keeps its sign.
  private static let wrapping = CharacterSet.whitespacesAndNewlines
    .union(CharacterSet(charactersIn: ".,;:!?…\"“”'‘’()[]"))

  /// Lower-cased words of a phrase, without the punctuation around the phrase.
  private static func words(_ phrase: String) -> [String] {
    phrase
      .trimmingCharacters(in: wrapping)
      .lowercased()
      .replacingOccurrences(of: "’", with: "'")
      .split { $0.isWhitespace || $0 == "-" }
      .map(String.init)
  }
}

enum DictationText {
  /// Rewrites misheard phrases to the spelling in the user's dictionary.
  static func corrections(from words: [DictionaryWord]) -> PhraseReplacer {
    PhraseReplacer(
      words.compactMap { word in
        guard let misheard = word.replaces, !word.text.isEmpty else { return nil }
        return (misheard, word.text)
      }
    )
  }

  /// Swaps spoken triggers for their snippets.
  static func expansions(from snippets: [Snippet]) -> PhraseReplacer {
    PhraseReplacer(
      snippets.compactMap { snippet in
        snippet.expansion.isEmpty ? nil : (snippet.trigger, snippet.expansion)
      }
    )
  }

  /// The small fix-up used when the language model is not: trims the text and
  /// starts it with a capital letter, except in the very casual style or
  /// when it starts with a word the user spells in lower case.
  static func tidy(_ text: String, style: WritingStyle, spellings: [String]) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard style != .veryCasual, let first = trimmed.first, first.isLowercase else { return trimmed }
    let startsWithSpelling = spellings.contains { spelling in
      guard !spelling.isEmpty, trimmed.hasPrefix(spelling) else { return false }
      let next = trimmed.dropFirst(spelling.count).first
      return next.map { !$0.isLetter && !$0.isNumber } ?? true
    }
    return startsWithSpelling ? trimmed : first.uppercased() + trimmed.dropFirst()
  }

  static func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
  }

  /// The model's clean-up of `transcript`, or `nil` when the reply cannot be
  /// trusted: empty, far longer than what was said (it answered or added
  /// text), or a small fraction of it (it summarised or refused).
  static func acceptedCleanUp(_ reply: String, of transcript: String) -> String? {
    let cleaned = DictationPrompts.unwrap(reply)
    guard !cleaned.isEmpty else { return nil }
    // Clean-up removes words and adds a little punctuation. It never doubles the text.
    guard cleaned.count <= transcript.count + transcript.count / 2 + 24 else { return nil }
    let said = wordCount(transcript)
    if said >= 12, wordCount(cleaned) * 4 < said { return nil }
    return cleaned
  }

  /// A message a person can read for any error.
  static func message(for error: any Error) -> String {
    if let known = error as? WisperError, let text = known.errorDescription { return text }
    return "Something went wrong. \(error.localizedDescription)"
  }
}
