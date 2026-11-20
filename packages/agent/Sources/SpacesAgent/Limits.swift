import Foundation
import SpacesDomain

// An agent may have been tricked by text inside a meeting, so everything it
// sends is treated as untrusted: there is a ceiling on how much it may send,
// and text the app will later show, type or write to a file is cleaned first.

/// The most an agent may send or store. Sizes of text are in characters.
enum Limits {
  /// Bytes in one MCP message (one line of input). A longer line is refused unread.
  static let line = 4 * 1_048_576
  /// How deep the lists and objects in one MCP message may sit inside each other.
  static let depth = 64
  /// Values (counted by their commas) in one MCP message.
  static let values = 10_000
  /// Change subscriptions one MCP session may hold open, and meetings each one may watch.
  static let subscriptions = 16
  static let watched = 100

  /// The `id` of one MCP request, which every reply repeats.
  static let requestID = 128
  /// Bytes kept from the end of a line that is too long, to find the `id` of the request in.
  static let lineEnd = 256

  /// An ID, a date, a filter: any argument with no larger limit of its own.
  static let short = 200
  static let path = 1_024
  static let title = 200
  /// The app cuts a title sent by link to this length, so a longer one is refused up front.
  static let linkTitle = 120
  static let tag = 50
  /// Values in one list argument, and tags on one meeting.
  static let listed = 50
  static let owner = 100
  static let action = 500
  /// Action items on one meeting.
  static let actions = 200
  /// One note added, and all of a meeting's notes together.
  static let notes = 100_000
  static let word = 80
  /// Words in the dictionary.
  static let words = 2_000
  static let trigger = 60
  static let expansion = 2_000
  static let snippets = 500

  /// Whether `text` has more than `limit` characters. Looks at no more than `limit` of them,
  /// so a huge text costs nothing to refuse.
  static func isLonger(_ text: String, than limit: Int) -> Bool {
    // A character is at least one byte, so text of few bytes is never too long.
    guard text.utf8.count > limit,
      let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex)
    else { return false }
    return end < text.endIndex
  }

  /// A number the way people write it: 100,000.
  static func plain(_ number: Int) -> String {
    var digits = String(number)
    var index = digits.count - 3
    while index > 0 {
      digits.insert(",", at: digits.index(digits.startIndex, offsetBy: index))
      index -= 3
    }
    return digits
  }

  /// The start of something the caller sent, on one line, for quoting back in an error.
  /// Never copies more than `length` characters, however long `text` is.
  static func echo(_ text: String, to length: Int = 80) -> String {
    guard let cut = text.index(text.startIndex, offsetBy: length, limitedBy: text.endIndex),
      cut < text.endIndex
    else { return Toolbox.oneLine(text) }
    return Toolbox.oneLine(String(text[..<cut])) + "…"
  }
}

extension Unicode.Scalar {
  /// A character that shows nothing itself and ends a line, moves the cursor or starts a
  /// terminal command.
  var isControl: Bool {
    switch properties.generalCategory {
    case .control, .lineSeparator, .paragraphSeparator: true
    default: false
    }
  }

  /// A character that makes the text around it read in another direction, so that what is
  /// shown is not what is there.
  var reordersText: Bool {
    (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
  }
}

extension Meeting {
  /// The title as it is written into a sentence or a list for people: one line, cut to the
  /// length a title can have, whatever the file holds. JSON output carries `title` as stored.
  var name: String { Toolbox.clipped(Toolbox.oneLine(title), to: Limits.title) }
}

extension Toolbox {
  /// `text` as one line: every line break, tab and control character becomes a space, runs of
  /// spaces become one, and the ends are trimmed. For titles, tags, owners and action items.
  static func oneLine(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      scalars.append(scalar.isControl || scalar.reordersText ? " " : scalar)
    }
    return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// Text of several lines as it is stored: line breaks and tabs are kept, every other
  /// control character is dropped, and the ends are trimmed. For notes, which are Markdown.
  static func multiline(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .lineSeparator, .paragraphSeparator: scalars.append("\n")
      case .control: if scalar == "\n" || scalar == "\t" { scalars.append(scalar) }
      default: scalars.append(scalar)
      }
    }
    return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Text that is safe to print on a terminal: control characters other than line breaks and
  /// tabs are shown as "?", so stored text can never send commands to the terminal (an escape
  /// sequence loses its escape character and is printed as plain letters). Characters that
  /// turn the reading direction around are shown the same way.
  static func printable(_ text: String) -> String {
    func unsafe(_ scalar: Unicode.Scalar) -> Bool {
      (scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t")
        || scalar.reordersText
    }
    guard text.unicodeScalars.contains(where: unsafe) else { return text }
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars { scalars.append(unsafe(scalar) ? "?" : scalar) }
    return String(scalars)
  }

  /// A short phrase the app will later type or listen for, as it will be stored. Unlike a
  /// title it is refused, not repaired, when it holds a line break or a control character:
  /// the caller should know that what it sent was not taken as it was.
  static func phrase(_ text: String, argument: String, limit: Int) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.unicodeScalars.contains(where: { $0.isControl || $0.reordersText }) else {
      throw AgentError.usage(
        "\"\(argument)\" must be one line of plain text, with no line breaks, tabs or control characters."
      )
    }
    let tidy = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !tidy.isEmpty else { throw AgentError.usage("\"\(argument)\" must not be empty.") }
    guard !Limits.isLonger(tidy, than: limit) else {
      throw AgentError.usage("\"\(argument)\" is too long. It can be at most \(limit) characters.")
    }
    return tidy
  }

  /// The words of a spoken phrase, the way the app compares what it hears: lower case,
  /// without the punctuation around it, split at spaces and hyphens.
  static func spokenWords(_ phrase: String) -> [String] {
    let wrapping = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?…\"“”'‘’()[]"))
    return phrase.trimmingCharacters(in: wrapping).lowercased()
      .replacingOccurrences(of: "’", with: "'")
      .split { $0.isWhitespace || $0 == "-" }
      .map(String.init)
  }
}
