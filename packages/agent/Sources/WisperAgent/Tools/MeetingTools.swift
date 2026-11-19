import Foundation
import WisperDomain

extension Catalogue {
  static let meetings: [Tool] = [
    Tool(
      path: ["meetings", "list"],
      title: "List meetings",
      summary: "List meetings, newest first.",
      description:
        "Lists the user's recorded meetings, newest first. Each entry is small: ID, title, start time, "
        + "length in minutes, status, tags, the first part of the summary, the number of open action items "
        + "and the number of transcript segments. It never returns transcripts. Use it to find a meeting's "
        + "ID, then call meetings_get for the notes or meetings_transcript for what was said. To find "
        + "meetings about a topic, use meetings_search instead.",
      params: [
        .number("limit", "The most meetings to return.", in: 1...200, fallback: 20),
        .text("since", "Only meetings that started at or after this moment. \(Toolbox.dateHelp)"),
        .text("until", "Only meetings that started before this moment. Same forms as since."),
        .choice(
          "status",
          ["recording", "processing", "ready", "failed"],
          "Only meetings in this state. \"ready\" means the transcript and notes are finished."
        ),
        .text("tag", "Only meetings that carry this tag."),
      ],
      hints: .reads,
      example: "wisper meetings list --since 7d --limit 5",
      run: { box, arguments in try await box.listMeetings(arguments) }
    ),
    Tool(
      path: ["meetings", "get"],
      title: "Get a meeting",
      summary: "Show one meeting: its notes, action items and details.",
      description:
        "Returns one meeting: title, times, status, tags, the AI summary, key points, decisions, action "
        + "items (each with its own ID), the user's own notes, and how long the transcript is. The "
        + "transcript itself is left out unless include_transcript is true, because transcripts are long. "
        + "Prefer meetings_transcript with a time range or a speaker when you only need part of it.",
      params: [
        .text("meeting", Catalogue.meetingHelp, required: true, positional: true),
        .flag("include_transcript", "Also return the whole transcript as text."),
      ],
      hints: .reads,
      aliases: [Alias(path: ["meetings", "show"], summary: "The same as \"meetings get\".")],
      example: "wisper meetings get latest",
      run: { box, arguments in try await box.getMeeting(arguments) }
    ),
    Tool(
      path: ["meetings", "transcript"],
      title: "Read a transcript",
      summary: "Read what was said in a meeting, all of it or one part.",
      description:
        "Returns the transcript of one meeting as text, one line per segment: \"[mm:ss] Speaker: words\". "
        + "The speaker is \"Me\" (the user's microphone), \"Others\" (everyone else on the call) or a name. "
        + "Narrow it with from and to (a time range) or speaker. Long transcripts come in pages: when the "
        + "result has next_offset, call again with that offset to read on.",
      params: [
        .text("meeting", Catalogue.meetingHelp, required: true, positional: true),
        .text("from", "Start of the range, from the start of the recording: seconds (90) or mm:ss (1:30)."),
        .text("to", "End of the range, in the same form as from."),
        .text("speaker", "Only lines from this speaker: \"me\", \"others\" or a name."),
        .number("offset", "How many matching segments to skip.", in: 0...1_000_000, fallback: 0),
        .number("limit", "The most segments to return.", in: 1...1_000, fallback: 200),
      ],
      hints: .reads,
      example: "wisper meetings transcript latest --from 10:00 --to 15:00",
      run: { box, arguments in try await box.transcript(arguments) }
    ),
    Tool(
      path: ["meetings", "search"],
      title: "Search meetings",
      summary: "Find where something was said or noted, across all meetings.",
      description:
        "Searches every meeting's title, tags, summary, key points, decisions, action items, the user's "
        + "notes and the transcript. It returns short matching snippets grouped by meeting, not whole "
        + "meetings. Transcript matches carry the time (\"at\", as mm:ss) and the speaker, so you can "
        + "follow up with meetings_transcript around that time. Matching ignores case. A query of several "
        + "words is first matched as an exact phrase; if nothing matches, as all of the words in one place.",
      params: [
        .text("query", "The word or phrase to look for.", required: true, positional: true),
        .number("limit", "The most snippets to return in total.", in: 1...100, fallback: 20),
        .number("per_meeting", "The most snippets to return for any one meeting.", in: 1...50, fallback: 5),
        .text("since", "Only search meetings that started at or after this moment. \(Toolbox.dateHelp)"),
      ],
      hints: .reads,
      example: "wisper meetings search \"pricing\"",
      run: { box, arguments in try await box.searchMeetings(arguments) }
    ),
    Tool(
      path: ["meetings", "add-note"],
      title: "Add a note to a meeting",
      summary: "Add text to the end of a meeting's notes.",
      description:
        "Adds text to the end of the user's own notes on a meeting. Nothing already there is changed. "
        + "The text is Markdown. Use it to record a follow-up, a link or a conclusion against the meeting. "
        + "To replace the notes instead, use meetings_update.",
      params: [
        .text("meeting", Catalogue.meetingHelp, required: true, positional: true),
        .text("text", "The Markdown to add.", required: true, positional: true),
      ],
      hints: .adds,
      example: "wisper meetings add-note latest \"Sam confirmed the migration is done.\"",
      run: { box, arguments in try await box.addNote(arguments) }
    ),
    Tool(
      path: ["meetings", "update"],
      title: "Change a meeting",
      summary: "Change a meeting's title, notes or tags.",
      description:
        "Changes a meeting's title, the user's notes or its tags. Give only what should change. notes "
        + "replaces all of the user's notes (use meetings_add_note to add to them instead). tags replaces "
        + "all tags; add_tags and remove_tags change them one by one. It does not touch the transcript or "
        + "the AI summary. It returns the meeting as it is afterwards.",
      params: [
        .text("meeting", Catalogue.meetingHelp, required: true, positional: true),
        .text("title", "The new title."),
        .text(
          "notes",
          "New Markdown for the user's notes. Replaces what is there. An empty text clears them."
        ),
        .list("tags", "The new full list of tags. Replaces what is there."),
        .list("add_tags", "Tags to add."),
        .list("remove_tags", "Tags to take away."),
      ],
      hints: .destroys,
      example: "wisper meetings update latest --title \"Pricing review\" --add-tags pricing,q4",
      run: { box, arguments in try await box.updateMeeting(arguments) }
    ),
    Tool(
      path: ["meetings", "export"],
      title: "Export a meeting as Markdown",
      summary: "Get a meeting as one Markdown document, or save it to a file.",
      description:
        "Returns one meeting as a Markdown document: title, date, summary, key points, decisions, action "
        + "items, the user's notes and the transcript. With path it saves the document to that file "
        + "instead of returning it, and returns where it was saved. It never overwrites a file that is "
        + "already there.",
      params: [
        .text("meeting", Catalogue.meetingHelp, required: true, positional: true),
        .text(
          "path",
          "Where to save the file. A folder is fine too: the file is then named after the meeting. A path "
            + "that is not absolute is taken from the folder the tool was started in."
        ),
        .flag("include_transcript", "Put the transcript in the document.", fallback: true),
      ],
      hints: .adds,
      example: "wisper meetings export latest --path ~/Desktop",
      run: { box, arguments in try await box.exportMeeting(arguments) }
    ),
    Tool(
      path: ["meetings", "delete"],
      title: "Delete a meeting",
      summary: "Delete a meeting, its transcript, notes and audio for good.",
      description:
        "Deletes one meeting for good: its transcript, notes, action items and audio. This cannot be "
        + "undone, so only call it when the user has clearly asked for that meeting to be deleted. It "
        + "needs the meeting's ID (or the start of it); \"latest\" is not accepted.",
      params: [
        .text(
          "meeting",
          "The meeting's full ID, or the first 4 or more characters of it.",
          required: true,
          positional: true
        )
      ],
      hints: .destroys,
      example: "wisper meetings delete 3F2A9C1E",
      run: { box, arguments in try await box.deleteMeeting(arguments) }
    ),
  ]
}

extension Toolbox {
  fileprivate func listMeetings(_ arguments: Arguments) async throws -> ToolOutput {
    var found = try await library.meetings()
    if let since = arguments.string("since") {
      let start = try date(from: since, argument: "since")
      found.removeAll { $0.startedAt < start }
    }
    if let until = arguments.string("until") {
      let end = try date(from: until, argument: "until")
      found.removeAll { $0.startedAt >= end }
    }
    if let status = arguments.string("status") {
      found.removeAll { $0.status.rawValue != status }
    }
    if let tag = arguments.string("tag") {
      found.removeAll { meeting in !meeting.tags.contains { Toolbox.same($0, tag) } }
    }
    let shown = Array(found.prefix(arguments.int("limit") ?? 20))
    var lines = shown.map(line(for:))
    if found.isEmpty {
      lines.append("No meetings found.")
    } else if shown.count < found.count {
      lines.append("")
      lines.append("Showing the newest \(shown.count) of \(found.count). Raise --limit to see more.")
    }
    return ToolOutput(
      data: [
        "total": .int(found.count),
        "returned": .int(shown.count),
        "meetings": .array(shown.map { .object(summary(of: $0)) }),
      ],
      text: lines.joined(separator: "\n")
    )
  }

  /// Everything about a meeting except its transcript.
  func details(of meeting: Meeting) -> JSONObject {
    var object: JSONObject = [
      "id": .string(meeting.id.uuidString),
      "title": .string(meeting.title),
      "started_at": .string(iso(meeting.startedAt)),
      "ended_at": meeting.endedAt.map { .string(iso($0)) },
      "duration_minutes": .int(Toolbox.minutes(meeting)),
      "status": .string(meeting.status.rawValue),
      "failure": meeting.failure.map(JSONValue.string),
      "tags": .strings(meeting.tags),
    ]
    if let notes = meeting.notes {
      object["summary"] = .string(notes.summary)
      object["key_points"] = .strings(notes.keyPoints)
      object["decisions"] = .strings(notes.decisions)
      object["action_items"] = .array(notes.actionItems.map { .object(Toolbox.json($0)) })
    } else {
      object["ai_notes"] = "none yet"
    }
    object["user_notes"] = .string(meeting.userNotes)
    var seen = Set<String>()
    let speakers = meeting.segments.map(\.speaker.label).filter { seen.insert($0).inserted }
    object["transcript_segments"] = .int(meeting.segments.count)
    object["speakers"] = .strings(speakers)
    object["uri"] = .string(WisperLink.showMeeting(meeting.id).url.absoluteString)
    return object
  }

  private func page(of meeting: Meeting, transcript: Bool) -> String {
    var copy = meeting
    if !transcript { copy.segments = [] }
    var head = ["ID: \(meeting.id.uuidString)", "Status: \(meeting.status.rawValue)"]
    if let failure = meeting.failure { head.append("Problem: \(failure)") }
    if !transcript && !meeting.segments.isEmpty {
      head.append(
        "Transcript: \(Toolbox.count(meeting.segments.count, "segment")) "
          + "(wisper meetings transcript \(Toolbox.short(meeting.id)))"
      )
    }
    return head.joined(separator: "\n") + "\n\n" + copy.markdown(timeZone: environment.timeZone)
  }

  fileprivate func getMeeting(_ arguments: Arguments) async throws -> ToolOutput {
    let meeting = try await meeting(arguments.text("meeting"))
    let withTranscript = arguments.bool("include_transcript")
    var data = details(of: meeting)
    if withTranscript { data["transcript"] = .string(meeting.transcriptText) }
    return ToolOutput(data: data, text: page(of: meeting, transcript: withTranscript))
  }

  fileprivate func transcript(_ arguments: Arguments) async throws -> ToolOutput {
    let meeting = try await meeting(arguments.text("meeting"))
    var segments = meeting.segments.sorted { $0.start < $1.start }
    if let from = arguments.string("from") {
      let start = try seconds(from: from, argument: "from")
      segments.removeAll { $0.end < start }
    }
    if let to = arguments.string("to") {
      let end = try seconds(from: to, argument: "to")
      segments.removeAll { $0.start > end }
    }
    if let speaker = arguments.string("speaker") {
      segments.removeAll { !Toolbox.same($0.speaker.label, speaker) }
    }
    let offset = arguments.int("offset") ?? 0
    let page = Array(segments.dropFirst(offset).prefix(arguments.int("limit") ?? 200))
    let text = page.map { "[\(Toolbox.stamp($0.start))] \($0.speaker.label): \($0.text)" }
      .joined(separator: "\n")
    let end = offset + page.count
    var data: JSONObject = [
      "meeting_id": .string(meeting.id.uuidString),
      "title": .string(meeting.title),
      "total_segments": .int(meeting.segments.count),
      "matching_segments": .int(segments.count),
      "returned_segments": .int(page.count),
    ]
    if end < segments.count { data["next_offset"] = .int(end) }
    data["transcript"] = .string(text)

    var lines = [text]
    if meeting.segments.isEmpty {
      lines = ["\"\(meeting.title)\" has no transcript" + (meeting.status == .ready ? "." : " yet.")]
    } else if page.isEmpty {
      lines = ["No part of the transcript matches."]
    } else if end < segments.count {
      lines.append("")
      lines.append(
        "Showing \(offset + 1) to \(end) of \(segments.count) segments. Add --offset \(end) to read on."
      )
    }
    return ToolOutput(data: data, text: lines.joined(separator: "\n"))
  }

  // MARK: Search

  private struct Hit {
    var place: String
    var at: TimeInterval?
    var speaker: String?
    var snippet: String
  }

  /// The text around a match, cut to a readable length.
  private static func snippet(_ text: String, around match: Range<String.Index>, radius: Int = 90) -> String {
    let start = text.index(match.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
    let end = text.index(match.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
    let middle = text[start..<end].split(whereSeparator: \.isNewline).joined(separator: " ")
    return (start > text.startIndex ? "…" : "") + middle + (end < text.endIndex ? "…" : "")
  }

  private static func hits(in meeting: Meeting, find: (String) -> Range<String.Index>?) -> [Hit] {
    var hits: [Hit] = []
    func look(_ place: String, _ text: String, at: TimeInterval? = nil, speaker: String? = nil) {
      guard let match = find(text) else { return }
      hits.append(Hit(place: place, at: at, speaker: speaker, snippet: snippet(text, around: match)))
    }
    look("title", meeting.title)
    for tag in meeting.tags { look("tag", tag) }
    if let notes = meeting.notes {
      look("summary", notes.summary)
      for point in notes.keyPoints { look("key_point", point) }
      for decision in notes.decisions { look("decision", decision) }
      for item in notes.actionItems { look("action_item", item.text) }
    }
    for line in meeting.userNotes.split(whereSeparator: \.isNewline) { look("user_notes", String(line)) }
    for segment in meeting.segments.sorted(by: { $0.start < $1.start }) {
      look("transcript", segment.text, at: segment.start, speaker: segment.speaker.label)
    }
    return hits
  }

  fileprivate func searchMeetings(_ arguments: Arguments) async throws -> ToolOutput {
    let query = arguments.text("query").trimmingCharacters(in: .whitespacesAndNewlines)
    var all = try await library.meetings()
    if let since = arguments.string("since") {
      let start = try date(from: since, argument: "since")
      all.removeAll { $0.startedAt < start }
    }
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    var mode = "phrase"
    var found = all.map { ($0, Toolbox.hits(in: $0) { $0.range(of: query, options: options) }) }
    if words.count > 1 && found.allSatisfy(\.1.isEmpty) {
      mode = "all_words"
      found = all.map { meeting in
        let hits = Toolbox.hits(in: meeting) { text in
          let ranges = words.map { text.range(of: $0, options: options) }
          return ranges.contains { $0 == nil } ? nil : ranges[0]
        }
        return (meeting, hits)
      }
    }
    found.removeAll { $0.1.isEmpty }

    var budget = arguments.int("limit") ?? 20
    let perMeeting = arguments.int("per_meeting") ?? 5
    var results: [JSONValue] = []
    var lines: [String] = []
    var returned = 0
    for (meeting, hits) in found where budget > 0 {
      let shown = Array(hits.prefix(min(perMeeting, budget)))
      budget -= shown.count
      returned += shown.count
      var entry: JSONObject = [
        "meeting_id": .string(meeting.id.uuidString),
        "title": .string(meeting.title),
        "started_at": .string(iso(meeting.startedAt)),
        "matches": .array(
          shown.map { hit in
            [
              "in": .string(hit.place),
              "at": hit.at.map { .string(Toolbox.stamp($0)) },
              "speaker": hit.speaker.map(JSONValue.string),
              "snippet": .string(hit.snippet),
            ]
          }
        ),
      ]
      if hits.count > shown.count { entry["more_matches"] = .int(hits.count - shown.count) }
      results.append(.object(entry))

      lines.append("\(Toolbox.short(meeting.id))  \(friendly(meeting.startedAt))  \(meeting.title)")
      for hit in shown {
        let place =
          hit.at.map { "[\(Toolbox.stamp($0))] \(hit.speaker ?? "")" }
          ?? hit.place.replacingOccurrences(of: "_", with: " ")
        lines.append("  \(place): \(hit.snippet)")
      }
      if hits.count > shown.count { lines.append("  … and \(hits.count - shown.count) more") }
    }
    let total = found.reduce(0) { $0 + $1.1.count }
    if found.isEmpty { lines = ["Nothing found for \"\(query)\"."] }
    return ToolOutput(
      data: [
        "query": .string(query),
        "matched_as": .string(mode),
        "total_matches": .int(total),
        "returned_matches": .int(returned),
        "meetings_matched": .int(found.count),
        "results": .array(results),
      ],
      text: lines.joined(separator: "\n")
    )
  }

  // MARK: Changes

  /// The result of `Library.updateMeeting`, or a plain error when the meeting was deleted meanwhile.
  func stored(_ meeting: Meeting?) throws -> Meeting {
    guard let meeting else {
      throw AgentError.failed(
        "That meeting was deleted a moment ago. List the meetings to see what is there."
      )
    }
    return meeting
  }

  fileprivate func addNote(_ arguments: Arguments) async throws -> ToolOutput {
    var meeting = try await meeting(arguments.text("meeting"))
    try ensureEditable(meeting)
    let addition = arguments.text("text").trimmingCharacters(in: .whitespacesAndNewlines)
    // Changed on the stored copy, in one step, so an edit made in the app meanwhile is kept.
    meeting = try await stored(
      library.updateMeeting(meeting.id) { stored in
        let existing = stored.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.userNotes = existing.isEmpty ? addition : existing + "\n\n" + addition
      }
    )
    return ToolOutput(
      data: [
        "meeting_id": .string(meeting.id.uuidString),
        "title": .string(meeting.title),
        "user_notes": .string(meeting.userNotes),
      ],
      text: "Added to the notes of \"\(meeting.title)\"."
    )
  }

  fileprivate func updateMeeting(_ arguments: Arguments) async throws -> ToolOutput {
    var meeting = try await meeting(arguments.text("meeting"))
    try ensureEditable(meeting)
    var changed: [String] = []
    var newTitle: String?
    if let title = arguments.string("title") {
      let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !clean.isEmpty else { throw AgentError.usage("\"title\" must not be empty.") }
      newTitle = clean
      changed.append("title")
    }
    let newNotes = arguments.string("notes")?.trimmingCharacters(in: .whitespacesAndNewlines)
    if newNotes != nil { changed.append("notes") }
    let replacement = arguments.strings("tags")
    let extra = arguments.strings("add_tags")
    let unwanted = arguments.strings("remove_tags")
    let changesTags = arguments.has("tags") || arguments.has("add_tags") || arguments.has("remove_tags")
    if changesTags { changed.append("tags") }
    guard !changed.isEmpty else {
      throw AgentError.usage(
        "Nothing to change. Give at least one of: title, notes, tags, add_tags, remove_tags."
      )
    }
    // Only the named fields change, on the stored copy, in one step: an edit made in the
    // app meanwhile is kept.
    let title = newTitle
    meeting = try await stored(
      library.updateMeeting(meeting.id) { stored in
        if let title { stored.title = title }
        if let newNotes { stored.userNotes = newNotes }
        guard changesTags else { return }
        var tags = replacement ?? stored.tags
        if let extra { tags += extra }
        if let unwanted {
          tags.removeAll { tag in unwanted.contains { Toolbox.same($0, tag) } }
        }
        stored.tags = Toolbox.tidy(tags)
      }
    )
    return ToolOutput(
      data: details(of: meeting),
      text: "Updated the \(changed.joined(separator: ", ")) of \"\(meeting.title)\"."
    )
  }

  fileprivate func exportMeeting(_ arguments: Arguments) async throws -> ToolOutput {
    var meeting = try await meeting(arguments.text("meeting"))
    if !arguments.bool("include_transcript") { meeting.segments = [] }
    let markdown = meeting.markdown(timeZone: environment.timeZone)
    guard let path = arguments.string("path"), !path.isEmpty else {
      return ToolOutput(
        data: [
          "meeting_id": .string(meeting.id.uuidString),
          "title": .string(meeting.title),
          "markdown": .string(markdown),
        ],
        text: markdown.trimmingCharacters(in: .newlines)
      )
    }
    let expanded = (path as NSString).expandingTildeInPath
    var file =
      expanded.hasPrefix("/")
      ? URL(fileURLWithPath: expanded) : environment.workingDirectory.appendingPathComponent(expanded)
    var isFolder: ObjCBool = false
    let files = FileManager.default
    if files.fileExists(atPath: file.path, isDirectory: &isFolder), isFolder.boolValue {
      let day = String(friendly(meeting.startedAt).prefix(10))
      let safe = meeting.title.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }
      file = file.appendingPathComponent("\(day) \(String(safe).prefix(80)).md")
    }
    file = file.standardizedFileURL
    guard !files.fileExists(atPath: file.path) else {
      throw AgentError.failed("There is already a file at \(file.path). Choose another path.")
    }
    do {
      try Data(markdown.utf8).write(to: file, options: .withoutOverwriting)
    } catch {
      throw AgentError.failed("Could not save the file at \(file.path): \(error.localizedDescription)")
    }
    return ToolOutput(
      data: [
        "meeting_id": .string(meeting.id.uuidString),
        "title": .string(meeting.title),
        "path": .string(file.path),
        "bytes": .int(markdown.utf8.count),
      ],
      text: "Saved \"\(meeting.title)\" to \(file.path)"
    )
  }

  fileprivate func deleteMeeting(_ arguments: Arguments) async throws -> ToolOutput {
    let meeting = try await meeting(arguments.text("meeting"), allowLatest: false)
    if meeting.status == .recording {
      throw AgentError.failed(
        "\"\(meeting.title)\" is still being recorded. Stop the recording first, then delete it."
      )
    }
    try await library.deleteMeeting(meeting.id)
    return ToolOutput(
      data: [
        "deleted": true,
        "meeting_id": .string(meeting.id.uuidString),
        "title": .string(meeting.title),
      ],
      text: "Deleted \"\(meeting.title)\" (\(meeting.id.uuidString))."
    )
  }
}
