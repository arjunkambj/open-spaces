import Foundation
import WisperDomain

/// Removes speech the microphone picked up from the speakers.
///
/// Without headphones the microphone hears the other people too, so their words arrive twice:
/// once on the system track and once, as "me", on the microphone track. A microphone segment
/// (or a sentence of one) is dropped when it is mostly the same words, in the same order, as
/// what the others said around the same time.
///
/// The rule is cautious on purpose. Losing something the user really said is worse than keeping
/// a repeated line, so short replies ("Yes, sounds good") are never dropped, and neither is a
/// sentence that reuses the others' words in a different order.
enum EchoFilter {
  /// Fewer words than this are never treated as an echo.
  static let minimumWords = 5
  /// Share of the words that must also be in the others' speech.
  static let wordShare = 0.8
  /// Share of the neighbouring word pairs that must also be in the others' speech. An echo
  /// with a misheard word or two still passes; the same words in another order do not.
  static let pairShare = 0.6
  /// How far apart in time, in seconds, the two tracks may be and still count as overlapping.
  static let slack: TimeInterval = 2

  static func removeEcho(from segments: [TranscriptSegment]) -> [TranscriptSegment] {
    let others = segments.filter { $0.speaker == .others }.map { (segment: $0, words: words(in: $0.text)) }
    guard !others.isEmpty else { return segments }
    return segments.compactMap { segment in
      guard segment.speaker == .me else { return segment }
      let heard = Heard(
        others
          .filter { $0.segment.start <= segment.end + slack && $0.segment.end >= segment.start - slack }
          .flatMap(\.words)
      )
      if heard.isEcho(words(in: segment.text)) { return nil }
      let sentences = sentences(in: segment.text)
      let isEcho = sentences.map { heard.isEcho(words(in: $0)) }
      guard isEcho.contains(true) else { return segment }
      guard let first = isEcho.firstIndex(of: false), let last = isEcho.lastIndex(of: false) else {
        return nil
      }
      var rest = segment
      rest.text = zip(sentences, isEcho).filter { !$0.1 }.map(\.0).joined(separator: " ")
      // The echo at either end took up its share of the time, so what is left starts later
      // (or ends earlier). That keeps a reply after the question it answers.
      let total = Double(max(1, sentences.reduce(0) { $0 + $1.count }))
      let length = segment.end - segment.start
      rest.start += length * Double(sentences[..<first].reduce(0) { $0 + $1.count }) / total
      rest.end -= length * Double(sentences[(last + 1)...].reduce(0) { $0 + $1.count }) / total
      return rest
    }
  }

  /// What the others said in one stretch of time.
  private struct Heard {
    private var counts: [String: Int] = [:]
    private var pairs: Set<String> = []

    init(_ words: [String]) {
      for word in words { counts[word, default: 0] += 1 }
      pairs = Set(EchoFilter.pairs(in: words))
    }

    func isEcho(_ words: [String]) -> Bool {
      guard words.count >= EchoFilter.minimumWords, !counts.isEmpty else { return false }
      var left = counts
      var shared = 0
      for word in words where left[word, default: 0] > 0 {
        left[word, default: 0] -= 1
        shared += 1
      }
      guard Double(shared) / Double(words.count) >= EchoFilter.wordShare else { return false }
      let own = EchoFilter.pairs(in: words)
      let sharedPairs = own.filter(pairs.contains).count
      return Double(sharedPairs) / Double(own.count) >= EchoFilter.pairShare
    }
  }

  private static func pairs(in words: [String]) -> [String] {
    zip(words, words.dropFirst()).map { "\($0) \($1)" }
  }

  /// The words of `text`, lower-cased and without accents or punctuation.
  static func words(in text: String) -> [String] {
    var words: [String] = []
    text.enumerateSubstrings(in: text.startIndex..., options: [.byWords]) { word, _, _, _ in
      guard let word else { return }
      words.append(word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
    }
    return words
  }

  private static func sentences(in text: String) -> [String] {
    var sentences: [String] = []
    text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences]) { sentence, _, _, _ in
      let trimmed = (sentence ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { sentences.append(trimmed) }
    }
    return sentences
  }
}
