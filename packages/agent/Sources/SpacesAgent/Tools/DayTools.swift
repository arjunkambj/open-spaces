import Foundation
import SpacesDomain

// One day at a glance: what was dictated, the meetings held, and the to-dos.

extension Catalogue {
  static let day: [Tool] = [
    Tool(
      path: ["day", "summary"],
      title: "Sum up a day",
      summary: "One day at a glance: dictations, meetings and action items.",
      description:
        "Returns one day in the user's time zone, midnight to midnight (today unless date is given): "
        + "how much the user dictated (count, words, minutes, the apps they dictated into most) with the "
        + "short text of each dictation, oldest first; the meetings that started that day with their time, "
        + "title and the first part of the summary; the action items from those meetings; and every "
        + "action item still open in any other meeting. Long text is cut short: use dictations_list, "
        + "meetings_get or actions_list for the full text. Use it to answer \"what did I do today?\" or "
        + "to write an end-of-day note.",
      params: [
        Param(
          name: "date",
          kind: .string,
          help:
            "Which day: a date such as 2026-11-18, \"today\" or \"yesterday\", or an age such as 2d for "
            + "two days ago.",
          positional: true,
          fallback: "today"
        ),
        .number(
          "limit",
          "The most dictations to list with their text. The counts always cover the whole day.",
          in: 0...500,
          fallback: 50
        ),
      ],
      hints: .reads,
      example: "spaces day summary yesterday",
      run: { box, arguments in try await box.daySummary(arguments) }
    )
  ]
}

extension Toolbox {
  /// The day a date argument falls on, from midnight to midnight in the user's time zone.
  func day(from text: String, argument: String) throws -> (start: Date, end: Date) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let start = calendar.startOfDay(for: Toolbox.sane(try date(from: text, argument: argument)))
    let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    return (start, end)
  }

  /// A local time of day for people, e.g. `09:30`.
  private func clock(_ date: Date) -> String { String(friendly(date).suffix(5)) }

  fileprivate func daySummary(_ arguments: Arguments) async throws -> ToolOutput {
    let given = arguments.string("date")?.trimmingCharacters(in: .whitespaces) ?? ""
    let (start, end) = try day(from: given.isEmpty ? "today" : given, argument: "date")
    let heading: String = {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = .current
      formatter.dateFormat = "EEEE d MMMM yyyy"
      return formatter.string(from: start)
    }()
    let isDay = { (date: Date) in date >= start && date < end }

    // Dictations, oldest first, the way the day went.
    let dictations = Array(try await library.dictations().filter { isDay($0.createdAt) }.reversed())
    let finished = dictations.filter { !$0.failed }
    let words = finished.reduce(0) { $0 + $1.wordCount }
    let seconds = finished.reduce(0) { $0 + Toolbox.whole($1.duration) }
    var perApp: [String: (count: Int, words: Int)] = [:]
    for dictation in finished {
      guard let app = dictation.appName.map(Toolbox.oneLine), !app.isEmpty else { continue }
      perApp[app, default: (0, 0)].count += 1
      perApp[app, default: (0, 0)].words += dictation.wordCount
    }
    let topApps = perApp.sorted {
      ($0.value.count, $0.value.words, $1.key) > ($1.value.count, $1.value.words, $0.key)
    }.prefix(5)
    let listed = Array(dictations.prefix(arguments.int("limit") ?? 50))

    // Meetings that started this day, oldest first.
    let all = try await library.meetings()
    let meetings = Array(all.filter { isDay($0.startedAt) }.reversed())
    let today = Set(meetings.map(\.id))
    let fromToday = meetings.flatMap { meeting in (meeting.notes?.actionItems ?? []).map { ($0, meeting) } }
    let openElsewhere = all.filter { !today.contains($0.id) }.flatMap { meeting in
      (meeting.notes?.actionItems ?? []).filter { !$0.done }.map { ($0, meeting) }
    }
    let openShown = Array(openElsewhere.prefix(Toolbox.mostOpenInDay))

    let data: JSONObject = [
      "date": .string(String(friendly(start).prefix(10))),
      "from": .string(iso(start)),
      "until": .string(iso(end)),
      "dictations": [
        "count": .int(dictations.count),
        "failed": .int(dictations.count - finished.count),
        "words": .int(words),
        "seconds": .int(seconds),
        "top_apps": .array(
          topApps.map {
            ["app": .string($0.key), "count": .int($0.value.count), "words": .int($0.value.words)]
          }
        ),
        "returned": .int(listed.count),
        "items": .array(
          listed.map { dictation in
            [
              "id": .string(dictation.id.uuidString),
              "created_at": .string(iso(dictation.createdAt)),
              "app": dictation.appName.map(JSONValue.string),
              "mode": dictation.mode == .command ? "command" : nil,
              "text": .string(Toolbox.clipped(dictation.text, to: Toolbox.dayTextLength)),
              "failure": dictation.failure.map(JSONValue.string),
              "words": .int(dictation.wordCount),
            ]
          }
        ),
      ],
      "meetings": [
        "count": .int(meetings.count),
        "minutes": .int(meetings.reduce(0) { $0 + Toolbox.minutes($1) }),
        "items": .array(meetings.map { .object(summary(of: $0)) }),
      ],
      "action_items_from_these_meetings": .array(fromToday.map { .object(entry($0.0, in: $0.1)) }),
      "open_in_other_meetings": [
        "total": .int(openElsewhere.count),
        "returned": .int(openShown.count),
        "items": .array(openShown.map { .object(entry($0.0, in: $0.1)) }),
      ],
    ]

    var lines = [heading, ""]
    if dictations.isEmpty {
      lines.append("Dictation: none.")
    } else {
      let failed = dictations.count - finished.count
      let minutes = seconds > 0 && seconds < 30 ? "under 1 min" : "\((seconds + 30) / 60) min"
      var line =
        "Dictation: \(Toolbox.count(dictations.count, "dictation"))"
        + (failed > 0 ? " (\(failed) failed)" : "") + ", \(Toolbox.count(words, "word")), \(minutes)."
      if !topApps.isEmpty {
        line += " Most in: " + topApps.map { "\($0.key) (\($0.value.count))" }.joined(separator: ", ") + "."
      }
      lines.append(line)
      for dictation in listed {
        let app = Toolbox.oneLine(dictation.appName ?? "-").padding(toLength: 10, withPad: " ", startingAt: 0)
        let text =
          dictation.failure.map { "(failed: \(Toolbox.clipped($0, to: 80)))" }
          ?? Toolbox.clipped(dictation.text, to: Toolbox.dayTextLength)
        lines.append("  \(clock(dictation.createdAt))  \(app)  \(text)")
      }
      if listed.count < dictations.count {
        lines.append("  … and \(dictations.count - listed.count) more. Raise --limit to see them.")
      }
    }

    lines.append("")
    if meetings.isEmpty {
      lines.append("Meetings: none.")
    } else {
      let minutes = meetings.reduce(0) { $0 + Toolbox.minutes($1) }
      lines.append("Meetings: \(meetings.count), \(minutes) min in all.")
      for meeting in meetings {
        var line =
          "  \(Toolbox.short(meeting.id))  \(clock(meeting.startedAt))  "
          + "\(Toolbox.minutes(meeting)) min  \(meeting.name)"
        if meeting.status != .ready { line += "  (\(meeting.status.rawValue))" }
        lines.append(line)
        if let summary = meeting.notes?.summary, !summary.isEmpty {
          lines.append("      " + Toolbox.clipped(summary, to: Toolbox.dayTextLength))
        }
      }
    }

    func group(_ items: [(ActionItem, Meeting)]) {
      var last: UUID?
      for (item, meeting) in items {
        if meeting.id != last {
          lines.append("  \(meeting.name)  (\(friendly(meeting.startedAt)), \(Toolbox.short(meeting.id)))")
          last = meeting.id
        }
        lines.append("    " + Toolbox.line(for: item))
      }
    }
    lines.append("")
    if fromToday.isEmpty {
      lines.append("Action items from these meetings: none.")
    } else {
      let done = fromToday.filter { $0.0.done }.count
      lines.append("Action items from these meetings: \(fromToday.count) (\(done) done).")
      group(fromToday)
    }
    lines.append("")
    if openElsewhere.isEmpty {
      lines.append("Still open in other meetings: none.")
    } else {
      lines.append("Still open in other meetings: \(openElsewhere.count).")
      group(openShown)
      if openShown.count < openElsewhere.count {
        lines.append("  … and \(openElsewhere.count - openShown.count) more: spaces actions list")
      }
    }
    return ToolOutput(data: data, text: lines.joined(separator: "\n"))
  }

  /// How much of a dictation or a summary a day summary shows.
  static let dayTextLength = 160
  /// The most open action items from other meetings a day summary lists.
  static let mostOpenInDay = 100
}
