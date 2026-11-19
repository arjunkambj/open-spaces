import Foundation
import WisperDomain

/// Why a tool could not do what was asked. The message is shown to the person
/// or the model as it is, so it says what to do next.
struct AgentError: Error, Equatable {
  enum Kind: Equatable {
    /// The request itself was wrong: a missing or malformed argument.
    case usage
    /// The request was fine but could not be carried out.
    case failed
  }

  var kind: Kind
  var message: String

  static func usage(_ message: String) -> AgentError { AgentError(kind: .usage, message: message) }
  static func failed(_ message: String) -> AgentError { AgentError(kind: .failed, message: message) }
}

/// What every tool works with: the library, the clock, and the shared ways of
/// reading IDs and dates and of writing them back out.
struct Toolbox: Sendable {
  let library: any Library
  let environment: WisperAgent.Environment

  var now: Date { environment.now() }

  // MARK: Dates

  /// ISO 8601 with the user's own offset, e.g. `2026-11-18T10:00:00+05:30`.
  func iso(_ date: Date) -> String {
    Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: environment.timeZone)
      .format(Toolbox.sane(date))
  }

  /// A date no formatter can choke on: between the years 1 and 9999 in every time zone,
  /// whatever a file holds.
  static func sane(_ date: Date) -> Date {
    let seconds = date.timeIntervalSince1970
    guard seconds.isFinite else { return Date(timeIntervalSince1970: 0) }
    // Two days inside the first and the last year, so no zone's offset can carry it out.
    return Date(timeIntervalSince1970: min(max(seconds, -62_135_424_000), 253_402_128_000))
  }

  /// A short local date and time for people, e.g. `2026-11-18 10:00`.
  func friendly(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = environment.timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: Toolbox.sane(date))
  }

  static let dateHelp =
    "An ISO 8601 date or date-time (2026-11-18 or 2026-11-18T09:30:00+05:30; no offset means the user's "
    + "time zone), or \"today\", \"yesterday\", or an age such as 36h, 7d or 2w."

  /// Reads a moment in time written in any of the forms in `dateHelp`.
  func date(from text: String, argument: String) throws -> Date {
    let value = text.trimmingCharacters(in: .whitespaces)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = environment.timeZone
    let today = calendar.startOfDay(for: now)
    switch value.lowercased() {
    case "now": return now
    case "today": return today
    case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today) ?? today
    default: break
    }
    // An age of more than a few centuries is a mistake, and must not overflow the sum below.
    if let unit = value.last, let amount = Int(value.dropLast()), (0...100_000).contains(amount) {
      let hours: Int? =
        switch unit {
        case "h", "H": 1
        case "d", "D": 24
        case "w", "W": 24 * 7
        default: nil
        }
      if let hours { return now.addingTimeInterval(-Double(amount * hours) * 3_600) }
    }
    let iso = ISO8601DateFormatter()
    for options: ISO8601DateFormatter.Options in [
      [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
    ] {
      iso.formatOptions = options
      if let date = iso.date(from: value) { return date }
    }
    let local = DateFormatter()
    local.locale = Locale(identifier: "en_US_POSIX")
    local.timeZone = environment.timeZone
    local.isLenient = false
    for format in [
      "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
    ] {
      local.dateFormat = format
      if let date = local.date(from: value) { return date }
    }
    throw AgentError.usage(
      "\"\(argument)\" could not be read as a date: \"\(Limits.echo(text))\". Use a form like "
        + "2026-11-18, "
        + "2026-11-18T09:30:00+05:30, today, yesterday or 7d."
    )
  }

  /// Reads a position in a recording: seconds (`90`), `mm:ss` (`1:30`) or `h:mm:ss`.
  func seconds(from text: String, argument: String) throws -> TimeInterval {
    let parts = text.trimmingCharacters(in: .whitespaces).split(
      separator: ":",
      omittingEmptySubsequences: false
    )
    let numbers = parts.compactMap { Double($0) }
    // "inf" and "nan" read as numbers too, and are not times.
    guard (1...3).contains(parts.count), numbers.count == parts.count,
      numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1e9 })
    else {
      throw AgentError.usage(
        "\"\(argument)\" could not be read as a time: \"\(Limits.echo(text))\". Use seconds (90) or "
          + "mm:ss (1:30)."
      )
    }
    return numbers.reduce(0) { $0 * 60 + $1 }
  }

  /// A position in a recording as `mm:ss`, the same way the Markdown export writes it.
  ///
  /// Times come straight from a file, so they may be negative, huge or not a number at all.
  static func stamp(_ seconds: TimeInterval) -> String {
    let total = Meeting.wholeSeconds(seconds)
    return String(format: "%02d:%02d", total / 60, total % 60)
  }

  /// The length of a meeting in whole minutes, rounded, and at least 1 when it has any length.
  static func minutes(_ meeting: Meeting) -> Int {
    let duration = meeting.duration
    return duration > 0 ? max(1, Meeting.wholeSeconds(duration + 30) / 60) : 0
  }

  /// A length of time as whole seconds, never negative, safe for any number a file may hold.
  static func whole(_ interval: TimeInterval) -> Int {
    interval.isFinite ? Int(min(max(interval, 0), 4_000_000_000)) : 0
  }

  // MARK: IDs

  /// The first 8 characters of an ID: enough to tell things apart on screen and to pass back in.
  static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

  /// The items whose ID is `reference` or starts with it. Hyphens and case do not matter.
  /// Returns `nil` when `reference` does not look like an ID at all.
  static func matching<Item>(_ reference: String, in items: [Item], id: (Item) -> UUID) -> [Item]? {
    // Only the characters an ID is made of: anything else (a NUL, say) is not quietly dropped.
    guard reference.unicodeScalars.allSatisfy({ $0.isASCII && ($0 == "-" || $0.properties.isASCIIHexDigit) })
    else { return nil }
    if let exact = UUID(uuidString: reference) { return items.filter { id($0) == exact } }
    let wanted = reference.uppercased().replacingOccurrences(of: "-", with: "")
    guard wanted.count >= 4, wanted.count <= 32, wanted.allSatisfy(\.isHexDigit) else { return nil }
    return items.filter { id($0).uuidString.replacingOccurrences(of: "-", with: "").hasPrefix(wanted) }
  }

  /// Finds one meeting from a full ID, a unique prefix of one, or "latest".
  func meeting(_ reference: String, allowLatest: Bool = true) async throws -> Meeting {
    try Toolbox.meeting(reference, in: try await library.meetings(), allowLatest: allowLatest)
  }

  /// Finds one meeting among `all`, which is every meeting, newest first.
  static func meeting(_ reference: String, in all: [Meeting], allowLatest: Bool = true) throws -> Meeting {
    var wanted = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    let link = "\(WisperLink.scheme)://meetings/"
    if wanted.lowercased().hasPrefix(link) { wanted = String(wanted.dropFirst(link.count)) }
    if ["latest", "last"].contains(wanted.lowercased()) {
      guard allowLatest else {
        throw AgentError.usage("Give the meeting's ID here. \"latest\" is not accepted for this.")
      }
      guard let newest = all.first else {
        throw AgentError.failed("There are no meetings yet.")
      }
      return newest
    }
    guard let found = Toolbox.matching(wanted, in: all, id: \.id) else {
      throw AgentError.usage(
        "\"\(Limits.echo(reference))\" is not a meeting ID. Use a full ID, the first 4 or more characters of one, or "
          + "\"latest\". List the meetings to see their IDs."
      )
    }
    switch found.count {
    case 1: return found[0]
    case 0:
      throw AgentError.failed(
        "No meeting has the ID \"\(Limits.echo(reference))\". List the meetings to see their IDs."
      )
    default:
      let choices = found.prefix(5).map { "\($0.id.uuidString) (\($0.name))" }.joined(separator: ", ")
      throw AgentError.failed(
        "More than one meeting has an ID starting with \"\(Limits.echo(reference))\": \(choices)."
      )
    }
  }

  /// Meetings that are being recorded or turned into notes are being written
  /// by the app; a second writer would lose one side's changes.
  func ensureEditable(_ meeting: Meeting) throws {
    switch meeting.status {
    case .recording:
      throw AgentError.failed(
        "\"\(meeting.name)\" is still being recorded. Stop the recording first, then try again."
      )
    case .processing:
      throw AgentError.failed(
        "Open Wisper is still writing the notes for \"\(meeting.name)\". Try again in a moment."
      )
    case .ready, .failed:
      break
    }
  }

  // MARK: Meetings as JSON

  /// The small form of a meeting used in lists. Never holds the transcript.
  func summary(of meeting: Meeting) -> JSONObject {
    var object: JSONObject = [
      "id": .string(meeting.id.uuidString),
      "title": .string(meeting.title),
      "started_at": .string(iso(meeting.startedAt)),
      "duration_minutes": .int(Toolbox.minutes(meeting)),
      "status": .string(meeting.status.rawValue),
    ]
    if !meeting.tags.isEmpty { object["tags"] = .strings(meeting.tags) }
    if let summary = meeting.notes?.summary, !summary.isEmpty {
      object["summary"] = .string(Toolbox.clipped(summary, to: 200))
    }
    object["open_action_items"] = .int(meeting.notes?.actionItems.filter { !$0.done }.count ?? 0)
    object["transcript_segments"] = .int(meeting.segments.count)
    return object
  }

  /// One line about a meeting for people.
  func line(for meeting: Meeting) -> String {
    var parts = [
      Toolbox.short(meeting.id),
      friendly(meeting.startedAt),
      "\(Toolbox.minutes(meeting)) min".padding(toLength: 7, withPad: " ", startingAt: 0),
      meeting.status.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0),
      meeting.name,
    ]
    if !meeting.tags.isEmpty {
      parts.append(meeting.tags.map { "#\(Toolbox.oneLine($0))" }.joined(separator: " "))
    }
    let open = meeting.notes?.actionItems.filter { !$0.done }.count ?? 0
    if open > 0 { parts.append("(\(open) open)") }
    return parts.joined(separator: "  ")
  }

  static func json(_ item: ActionItem) -> JSONObject {
    [
      "id": .string(item.id.uuidString),
      "text": .string(item.text),
      "owner": item.owner.map(JSONValue.string),
      "done": .bool(item.done),
    ]
  }

  static func line(for item: ActionItem) -> String {
    "[\(item.done ? "x" : " ")] \(short(item.id))  \(oneLine(item.text))"
      + (item.owner.map { "  (\(oneLine($0)))" } ?? "")
  }

  // MARK: Text

  /// Seconds as a JSON number: whole when it can be, two decimals otherwise.
  /// Never negative, and safe for any number a file may hold.
  static func number(_ seconds: TimeInterval) -> JSONValue {
    guard seconds.isFinite else { return .int(0) }
    let safe = min(max(seconds, 0), 4_000_000_000)
    return safe.rounded() == safe ? .int(Int(safe)) : .double((safe * 100).rounded() / 100)
  }

  static func clipped(_ text: String, to length: Int) -> String {
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    return flat.count <= length ? flat : String(flat.prefix(length - 1)) + "…"
  }

  static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(number) \(number == 1 ? singular : plural ?? singular + "s")"
  }

  /// Makes each value one clean line, drops empty ones and repeats (ignoring case), keeps the order.
  static func tidy(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.map(oneLine).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
  }

  static func same(_ a: String, _ b: String) -> Bool {
    a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
  }
}
