import Foundation
import WisperDomain

/// One day of dictation history, ready to show.
struct HomeHistoryDay: Identifiable, Equatable {
  /// The start of the day.
  var id: Date
  /// "Today", "Yesterday", or the date.
  var title: String
  /// Newest first.
  var entries: [Dictation]
}

/// How the history list is searched, grouped and labelled.
enum HomeHistory {
  /// How many entries are shown before "Show older dictations" is needed.
  static let pageSize = 100
  /// Text no longer than this fits in a row at every width.
  static let shortTextLength = 60

  /// The entries that match what was typed in the search field: the text, what was heard,
  /// or the app it went into. Case and accents are ignored. An empty query matches everything.
  static func filter(_ dictations: [Dictation], query: String) -> [Dictation] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return dictations }
    return dictations.filter { dictation in
      contains(dictation.text, needle) || contains(dictation.rawText, needle)
        || contains(dictation.appName ?? "", needle)
    }
  }

  private static func contains(_ text: String, _ needle: String) -> Bool {
    text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  /// Groups entries by the day they were made, newest day first.
  static func days(
    _ dictations: [Dictation],
    now: Date = Date(),
    calendar: Calendar = .current,
    locale: Locale = .current
  ) -> [HomeHistoryDay] {
    var days: [HomeHistoryDay] = []
    for dictation in dictations.sorted(by: { $0.createdAt > $1.createdAt }) {
      let day = calendar.startOfDay(for: dictation.createdAt)
      if days.last?.id == day {
        days[days.count - 1].entries.append(dictation)
      } else {
        let title = dayTitle(day, now: now, calendar: calendar, locale: locale)
        days.append(HomeHistoryDay(id: day, title: title, entries: [dictation]))
      }
    }
    return days
  }

  /// "Today", "Yesterday", then the weekday and date. The year is added for other years.
  static func dayTitle(
    _ day: Date,
    now: Date = Date(),
    calendar: Calendar = .current,
    locale: Locale = .current
  ) -> String {
    let today = calendar.startOfDay(for: now)
    let start = calendar.startOfDay(for: day)
    if start == today { return "Today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), start == yesterday {
      return "Yesterday"
    }
    var format = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
      .weekday(.wide).month(.wide).day()
    if calendar.component(.year, from: start) != calendar.component(.year, from: today) {
      format = format.year()
    }
    return start.formatted(format)
  }

  /// The time of day of an entry, such as "9:41 am".
  static func time(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
    date.formatted(
      Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute()
    )
    .lowercased()
  }

  /// A length of audio as minutes and seconds, such as "0:06".
  static func clock(_ seconds: TimeInterval) -> String {
    let total = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
    let rest = total % 60
    return "\(total / 60):\(rest < 10 ? "0" : "")\(rest)"
  }

  /// Whether a text could need more lines than a row shows. Short one-liners never do,
  /// so rows can skip measuring them.
  static func mayNeedCutting(_ text: String) -> Bool {
    text.count > shortTextLength || text.contains(where: \.isNewline)
  }
}

/// The words and numbers on the home screen.
enum HomeText {
  /// How fast most people type, in words a minute. Used to estimate the time saved.
  static let typingSpeed = 40

  static func greeting(name: String) -> String {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "Welcome back" : "Welcome back, \(name)"
  }

  /// A count in a short form: 950, 1.2K, 14.4K, 120K, 2.5M.
  static func compact(_ count: Int) -> String {
    let count = max(0, count)
    if count < 1_000 { return "\(count)" }
    if count < 1_000_000 { return scaled(count, by: 1_000) + "K" }
    return scaled(count, by: 1_000_000) + "M"
  }

  /// `count / unit` with one decimal place, rounded down, and no ".0".
  private static func scaled(_ count: Int, by unit: Int) -> String {
    let tenths = count / (unit / 10)
    return tenths % 10 == 0 || tenths >= 1_000 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
  }

  /// How much typing the dictations saved, such as "12 minutes" or "1.5 hours".
  /// `nil` when there is nothing to show yet.
  static func timeSaved(_ stats: DictationStats, typingSpeed: Int = HomeText.typingSpeed) -> String? {
    guard stats.totalWords > 0, typingSpeed > 0, stats.wordsPerMinute > typingSpeed else { return nil }
    let words = Double(stats.totalWords)
    let minutes = words / Double(typingSpeed) - words / Double(stats.wordsPerMinute)
    let whole = Int(minutes.rounded())
    guard whole >= 1 else { return nil }
    if whole < 60 { return whole == 1 ? "1 minute" : "\(whole) minutes" }
    let tenths = Int((minutes / 6).rounded())
    if tenths == 10 { return "1 hour" }
    return tenths % 10 == 0 ? "\(tenths / 10) hours" : "\(tenths / 10).\(tenths % 10) hours"
  }

  /// The labels of the keys of a shortcut, in the order they are shown: `["fn"]`, `["⌃", "⌘", "V"]`.
  /// Empty when there is no shortcut.
  static func keyLabels(_ combo: KeyCombo?) -> [String] {
    guard let combo, !combo.isEmpty else { return [] }
    return combo.orderedModifiers.map(\.symbol) + (combo.keyCode.map { [keyName($0)] } ?? [])
  }

  /// The name of a key by its position on a US keyboard.
  static func keyName(_ keyCode: UInt16) -> String {
    keyNames[keyCode] ?? "Key \(keyCode)"
  }

  private static let keyNames: [UInt16: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
    13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
    24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
    35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
    45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc", 57: "Caps Lock",
    76: "Enter", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10",
    111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
  ]
}

/// What Home does when a retry of a failed dictation comes back.
///
/// A retry started from Home never types into another app: the text is saved to the history
/// and copied, and a toast says so. When the retry fails again there is nothing to copy, and
/// the row goes on showing why.
struct HomeRetry: Equatable {
  /// The text to put on the clipboard, when the retry made some.
  var textToCopy: String?
  var toast: Toast

  /// - result: what `DictationEngine.retry(_:insert:)` returned.
  init(_ result: Dictation?) {
    if let result, !result.failed, !result.text.isEmpty {
      textToCopy = result.text
      toast = Toast("Copied to the clipboard")
    } else {
      textToCopy = nil
      toast = Toast("That did not work. Try again in a moment.", tone: .error)
    }
  }
}
