import Foundation
import WisperDomain
import WisperEngine

/// Where a meeting is in its life, as the screens show it.
enum MeetingPhase: Equatable, Sendable {
  /// Being recorded right now by this app.
  case live
  /// The transcript or the notes are being made.
  case processing
  /// Could not be finished.
  case failed
  /// Marked as recording, but nothing is recording it: the app quit in the middle.
  case interrupted
  case ready
}

/// Something that went wrong with a meeting, and what the user can do about it.
struct MeetingProblem: Equatable, Sendable {
  enum Remedy: Equatable, Sendable {
    /// Process the kept audio again.
    case retry
    /// Write the notes again from the transcript.
    case writeNotes
  }

  var title: String
  var message: String?
  /// What can be done about it. `nil` when nothing can: what was lost is gone for good, so the
  /// text is shown without a button.
  var remedy: Remedy?
  /// The label of the button that runs the remedy.
  var actionTitle: String
  /// Nothing of the meeting could be used. Otherwise only a part is missing.
  var isSevere: Bool
}

/// Meetings under one date heading.
struct MeetingGroup: Identifiable, Equatable {
  var title: String
  var meetings: [Meeting]
  var id: String { title }
}

/// A stretch of transcript said by one speaker.
struct TranscriptTurn: Identifiable, Equatable {
  /// The ID of the first segment.
  var id: UUID
  var speaker: Speaker
  /// Seconds from the start of the recording.
  var start: TimeInterval
  var segments: [TranscriptSegment]
}

/// One place where the text being looked for appears in a transcript.
struct TranscriptMatch: Equatable {
  var turn: UUID
  var segment: UUID
  var range: Range<String.Index>
}

/// What the list's search runs for. A value that differs from the last one means "search again":
/// for new text, and when the stored meetings changed while there is text to look for.
struct MeetingSearchTrigger: Equatable, Sendable {
  /// The text to look for, without the blank space around it. Empty means nothing is searched for.
  let text: String
  /// How many times the stored meetings changed under a search.
  let round: Int

  init(query: String, round: Int = 0) {
    text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    self.round = round
  }

  /// The trigger once the stored meetings have changed: a new one while searching, so that the
  /// results follow a meeting that was added, changed or deleted; the same one otherwise.
  func afterMeetingsChanged() -> MeetingSearchTrigger {
    text.isEmpty ? self : MeetingSearchTrigger(query: text, round: round &+ 1)
  }
}

/// The logic of the Meetings screens that does not need a view: grouping, wording, searching.
enum MeetingsLogic {
  // MARK: Phase and problems

  static func phase(
    of meeting: Meeting,
    liveID: Meeting.ID?,
    processing: Set<Meeting.ID>
  ) -> MeetingPhase {
    if meeting.id == liveID { return .live }
    if processing.contains(meeting.id) || meeting.status == .processing { return .processing }
    switch meeting.status {
    case .failed: return .failed
    case .recording: return .interrupted
    case .processing, .ready: return .ready
    }
  }

  /// What is wrong with the meeting, if anything the user can act on.
  static func problem(of meeting: Meeting, phase: MeetingPhase) -> MeetingProblem? {
    switch phase {
    case .live, .processing:
      return nil
    case .interrupted:
      return MeetingProblem(
        title: "This recording was cut short.",
        message: "Finish it to get a transcript and notes from what was recorded.",
        remedy: .retry,
        actionTitle: "Finish",
        isSevere: false
      )
    case .failed:
      let text = notice(meeting.failure ?? "")
      let canRetry = MeetingEngine.canRetry(meeting)
      return MeetingProblem(
        title: text.title.isEmpty ? "This meeting could not be finished." : text.title,
        message: text.message
          ?? (canRetry ? "The recording is kept on this device, so you can try again." : nil),
        remedy: canRetry ? .retry : nil,
        actionTitle: "Try again",
        isSevere: true
      )
    case .ready:
      guard let failure = meeting.failure, !failure.isEmpty else { return nil }
      let text = notice(failure)
      let notesOnly = failure.hasPrefix(notesFailure)
      // The engine knows which failures a new try can put right. A part that was never saved
      // is not one of them: the meeting says so, and there is nothing to press.
      let remedy: MeetingProblem.Remedy? =
        notesOnly ? .writeNotes : MeetingEngine.canRetry(meeting) ? .retry : nil
      return MeetingProblem(
        title: text.title,
        message: text.message,
        remedy: remedy,
        actionTitle: notesOnly ? "Write notes" : "Try again",
        isSevere: false
      )
    }
  }

  /// How the meeting engine starts the failure of a meeting whose notes could not be written.
  static let notesFailure = "The notes could not be written."

  /// Splits a message into its first sentence, used as a title, and the rest.
  static func notice(_ text: String) -> (title: String, message: String?) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let stop = text.range(of: ". ") else { return (text, nil) }
    let rest = text[stop.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    return (String(text[..<stop.lowerBound]) + ".", rest.isEmpty ? nil : rest)
  }

  // MARK: The list

  /// Puts meetings under date headings: Today, Yesterday, This week, then one per month.
  /// Keeps the order the meetings come in.
  static func groups(_ meetings: [Meeting]) -> [MeetingGroup] {
    var groups: [MeetingGroup] = []
    for meeting in meetings {
      let title = heading(for: meeting.startedAt)
      if let index = groups.firstIndex(where: { $0.title == title }) {
        groups[index].meetings.append(meeting)
      } else {
        groups.append(MeetingGroup(title: title, meetings: [meeting]))
      }
    }
    return groups
  }

  static func heading(for date: Date) -> String {
    switch age(of: date) {
    case .today: return "Today"
    case .yesterday: return "Yesterday"
    case .thisWeek: return "This week"
    case .thisYear: return date.formatted(style.month(.wide))
    case .older: return date.formatted(style.month(.wide).year())
    }
  }

  /// When a meeting started, said as briefly as its date heading allows: the time alone under
  /// Today and Yesterday, with the weekday under This week, with the day under a month.
  static func when(_ date: Date) -> String {
    let time = date.formatted(style.hour().minute())
    switch age(of: date) {
    case .today, .yesterday:
      return time
    case .thisWeek:
      return "\(date.formatted(style.weekday(.wide))), \(time)"
    case .thisYear:
      return "\(date.formatted(style.month(.abbreviated).day())), \(time)"
    case .older:
      return "\(date.formatted(style.month(.abbreviated).day().year())), \(time)"
    }
  }

  private enum Age { case today, yesterday, thisWeek, thisYear, older }

  private static func age(of date: Date) -> Age {
    let now = Date()
    let calendar = Calendar.current
    // A clock that jumped can put a meeting in the future. It still belongs to today.
    if date > now || calendar.isDate(date, inSameDayAs: now) { return .today }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(date, inSameDayAs: yesterday)
    {
      return .yesterday
    }
    if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
    return calendar.isDate(date, equalTo: now, toGranularity: .year) ? .thisYear : .older
  }

  private static var style: Date.FormatStyle {
    let calendar = Calendar.current
    return Date.FormatStyle(locale: .current, calendar: calendar, timeZone: calendar.timeZone)
  }

  /// How long a meeting was, in words: "31 min", "1 hr 5 min". `nil` when it has no length.
  static func length(_ seconds: TimeInterval) -> String? {
    guard seconds > 0 else { return nil }
    let minutes = Int((seconds / 60).rounded())
    if minutes < 1 { return "Under 1 min" }
    if minutes < 60 { return "\(minutes) min" }
    let rest = minutes % 60
    return rest == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(rest) min"
  }

  /// A running time or a place in the recording: "0:07", "12:34", "1:02:03".
  static func clock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let (hours, minutes, rest) = (total / 3_600, total / 60 % 60, total % 60)
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
  }

  /// One line that says what the meeting was about: the summary, else the user's notes,
  /// else the first words that were said.
  static func preview(of meeting: Meeting) -> String? {
    for candidate in [meeting.notes?.summary, meeting.userNotes, meeting.segments.first?.text] {
      let line = oneLine(String((candidate ?? "").prefix(400)))
      if !line.isEmpty { return line }
    }
    return nil
  }

  /// Up to three tags in one line, then how many more there are: "planning · platform · growth +2".
  static func tagLine(_ tags: [String]) -> String {
    let shown = tags.prefix(3).joined(separator: " · ")
    return tags.count > 3 ? "\(shown) +\(tags.count - 3)" : shown
  }

  /// What the empty list says: what a recording gives, what is recorded, and the one rule.
  static func firstMeetingHint(_ idiom: Wisper.Idiom) -> String {
    let sound =
      idiom == .phone
      ? "An iPhone cannot record the sound of other apps, so put a call on speaker."
      : "Both sides of a call are recorded: your microphone and the sound your Mac plays."
    return "Record a meeting to get its transcript and notes. \(sound) Tell people before you record them."
  }

  static func openActionItems(in meeting: Meeting) -> Int {
    meeting.notes?.actionItems.filter { !$0.done }.count ?? 0
  }

  /// A name for the exported file, without the extension.
  static func fileName(for meeting: Meeting) -> String {
    let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
    let name = oneLine(meeting.title.components(separatedBy: unsafe).joined(separator: " "))
    return name.isEmpty ? "Meeting" : String(name.prefix(80))
  }

  static func oneLine(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  // MARK: Tags

  /// The tags in what the user typed: split at commas, lower case, no "#", no doubles.
  static func tags(from typed: String) -> [String] {
    var result: [String] = []
    for piece in typed.split(separator: ",") {
      var tag = oneLine(String(piece)).lowercased()
      while tag.hasPrefix("#") { tag.removeFirst() }
      tag = String(tag.trimmingCharacters(in: .whitespaces).prefix(32))
      if !tag.isEmpty, !result.contains(tag) { result.append(tag) }
    }
    return result
  }

  /// `tags` with the typed ones added at the end. A tag that is already there is not added again.
  static func adding(_ typed: String, to tags: [String]) -> [String] {
    var result = tags
    for tag in self.tags(from: typed)
    where !result.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
      result.append(tag)
    }
    return result
  }

  // MARK: Transcript

  /// A speaker's turn is cut after this many seconds, so a long talk still gets time stamps.
  static let turnSeconds: TimeInterval = 120

  /// Groups segments that follow each other and have the same speaker. Segments come out in
  /// the order they were said, without the blank space around their text; empty ones are left out.
  static func turns(_ segments: [TranscriptSegment]) -> [TranscriptTurn] {
    let ordered = segments.enumerated()
      .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
      .compactMap { _, segment -> TranscriptSegment? in
        var segment = segment
        segment.text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return segment.text.isEmpty ? nil : segment
      }
    var turns: [TranscriptTurn] = []
    for segment in ordered {
      if let last = turns.last, last.speaker == segment.speaker, segment.start - last.start < turnSeconds {
        turns[turns.count - 1].segments.append(segment)
      } else {
        turns.append(
          TranscriptTurn(id: segment.id, speaker: segment.speaker, start: segment.start, segments: [segment])
        )
      }
    }
    return turns
  }

  /// Where `query` appears in `text`, ignoring case and accents.
  static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return [] }
    var found: [Range<String.Index>] = []
    var from = text.startIndex
    while from < text.endIndex,
      let range = text.range(
        of: needle,
        options: [.caseInsensitive, .diacriticInsensitive],
        range: from..<text.endIndex
      ),
      !range.isEmpty
    {
      found.append(range)
      from = range.upperBound
    }
    return found
  }

  /// Every place `query` appears in the transcript, from top to bottom.
  static func matches(of query: String, in turns: [TranscriptTurn]) -> [TranscriptMatch] {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    return turns.flatMap { turn in
      turn.segments.flatMap { segment in
        ranges(of: query, in: segment.text).map {
          TranscriptMatch(turn: turn.id, segment: segment.id, range: $0)
        }
      }
    }
  }

  /// The match after (`by: 1`) or before (`by: -1`) `index`, going round at the ends.
  static func step(_ index: Int, by offset: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return ((index + offset) % count + count) % count
  }

  // MARK: Questions

  /// Questions offered before the user has asked one.
  static let suggestedQuestions = [
    "What was decided?",
    "What do I need to do next?",
    "What is still open?",
  ]
}
