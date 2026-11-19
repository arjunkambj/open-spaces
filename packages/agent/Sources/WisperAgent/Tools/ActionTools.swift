import Foundation
import WisperDomain

extension Catalogue {
  private static let actionHelp =
    "Which action item: its full ID, or the first 4 or more characters of it. Action item IDs come from "
    + "actions_list and meetings_get."

  static let actions: [Tool] = [
    Tool(
      path: ["actions", "list"],
      title: "List action items",
      summary: "List action items from all meetings.",
      description:
        "Lists action items (to-dos) from every meeting, newest meeting first. By default only the open "
        + "ones. Each item has its own ID, its text, its owner when one was named, whether it is done, "
        + "and the meeting it came from. Use it to answer \"what do I still have to do?\", then "
        + "actions_set_done to tick items off.",
      params: [
        .choice("status", ["open", "done", "all"], "Which items to return.", fallback: "open"),
        .text("owner", "Only items whose owner contains this name. Case does not matter."),
        .text("meeting", "Only items from this meeting. \(Catalogue.meetingHelp)"),
        .number("limit", "The most items to return.", in: 1...500, fallback: 100),
      ],
      hints: .reads,
      example: "wisper actions list --owner Alex",
      run: { box, arguments in try await box.listActions(arguments) }
    ),
    Tool(
      path: ["actions", "add"],
      title: "Add an action item",
      summary: "Add an action item to a meeting.",
      description:
        "Adds a new, open action item to a meeting and returns it with its new ID. Use it when the user "
        + "asks to note a to-do against a meeting.",
      params: [
        .text("meeting", Catalogue.meetingHelp, required: true, positional: true),
        .text(
          "text",
          "What needs to be done, on one line.",
          required: true,
          positional: true,
          limit: Limits.action
        ),
        .text("owner", "Who should do it.", limit: Limits.owner),
      ],
      hints: .adds,
      example: "wisper actions add latest \"Send the proposal\" --owner Alex",
      run: { box, arguments in try await box.addAction(arguments) }
    ),
    Tool(
      path: ["actions", "set-done"],
      title: "Tick an action item off",
      summary: "Mark an action item as done, or as open again.",
      description:
        "Marks one action item as done. Pass done=false to mark it as open again. It returns the item "
        + "as it is afterwards.",
      params: [
        .text("action", actionHelp, required: true, positional: true),
        .flag("done", "true to tick the item off, false to open it again.", fallback: true),
      ],
      hints: .sets,
      aliases: [
        Alias(path: ["actions", "done"], summary: "Mark an action item as done.", preset: ["done": true]),
        Alias(
          path: ["actions", "reopen"],
          summary: "Mark an action item as open again.",
          preset: ["done": false]
        ),
      ],
      example: "wisper actions done 7B1D4F02",
      run: { box, arguments in try await box.setActionDone(arguments) }
    ),
    Tool(
      path: ["actions", "update"],
      title: "Change an action item",
      summary: "Change the text or the owner of an action item.",
      description:
        "Changes the text or the owner of one action item. Give only what should change. An empty owner "
        + "removes the owner. To tick an item off, use actions_set_done instead.",
      params: [
        .text("action", actionHelp, required: true, positional: true),
        .text("text", "The new text, on one line.", limit: Limits.action),
        .text("owner", "The new owner. An empty text removes the owner.", limit: Limits.owner),
      ],
      hints: .destroys,
      aliases: [Alias(path: ["actions", "edit"], summary: "The same as \"actions update\".")],
      example: "wisper actions update 7B1D4F02 --owner Priya",
      run: { box, arguments in try await box.updateAction(arguments) }
    ),
    Tool(
      path: ["actions", "remove"],
      title: "Remove an action item",
      summary: "Remove an action item for good.",
      description:
        "Removes one action item from its meeting for good. To keep a record that it was finished, use "
        + "actions_set_done instead.",
      params: [.text("action", actionHelp, required: true, positional: true)],
      hints: .destroys,
      example: "wisper actions remove 7B1D4F02",
      run: { box, arguments in try await box.removeAction(arguments) }
    ),
  ]
}

extension Toolbox {
  private func entry(_ item: ActionItem, in meeting: Meeting) -> JSONObject {
    var object = Toolbox.json(item)
    object["meeting_id"] = .string(meeting.id.uuidString)
    object["meeting_title"] = .string(meeting.title)
    object["meeting_started_at"] = .string(iso(meeting.startedAt))
    return object
  }

  /// Finds one action item, in any meeting, from its ID or the start of it.
  private func action(_ reference: String) async throws -> (meeting: Meeting, index: Int) {
    let wanted = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    var places: [(meeting: Meeting, index: Int)] = []
    for meeting in try await library.meetings() {
      for index in (meeting.notes?.actionItems ?? []).indices { places.append((meeting, index)) }
    }
    let found = Toolbox.matching(wanted, in: places) { $0.meeting.notes?.actionItems[$0.index].id ?? UUID() }
    guard let found else {
      throw AgentError.usage(
        "\"\(Limits.echo(reference))\" is not an action item ID. Use a full ID or the first 4 or more characters of one. "
          + "List the action items to see their IDs."
      )
    }
    switch found.count {
    case 1: return found[0]
    case 0:
      throw AgentError.failed(
        "No action item has the ID \"\(Limits.echo(reference))\". List the action items to see their IDs."
      )
    default:
      throw AgentError.failed(
        "More than one action item has an ID starting with \"\(Limits.echo(reference))\". Give more of "
          + "the ID."
      )
    }
  }

  /// Applies `change` to one action item and saves its meeting. Returning
  /// `false` from `change` removes the item.
  private func change(
    _ reference: String,
    _ change: (inout ActionItem) throws -> Bool
  ) async throws -> (item: ActionItem, meeting: Meeting) {
    let place = try await action(reference)
    var meeting = place.meeting
    try ensureEditable(meeting)
    var item = (meeting.notes ?? MeetingNotes()).actionItems[place.index]
    let keep = try change(&item)
    let changed = item
    // The item is found again by its ID on the stored copy, so a change made in the app
    // meanwhile (another item ticked, notes edited) is kept.
    meeting = try await stored(
      library.updateMeeting(meeting.id) { stored in
        var notes = stored.notes ?? MeetingNotes()
        guard let index = notes.actionItems.firstIndex(where: { $0.id == changed.id }) else { return }
        if keep {
          notes.actionItems[index] = changed
        } else {
          notes.actionItems.remove(at: index)
        }
        stored.notes = notes
      }
    )
    return (item, meeting)
  }

  fileprivate func listActions(_ arguments: Arguments) async throws -> ToolOutput {
    var meetings = try await library.meetings()
    if let reference = arguments.string("meeting") {
      let only = try await meeting(reference)
      meetings = meetings.filter { $0.id == only.id }
    }
    let status = arguments.string("status") ?? "open"
    let owner = arguments.string("owner")
    var found: [(item: ActionItem, meeting: Meeting)] = []
    var open = 0
    var done = 0
    for meeting in meetings {
      for item in meeting.notes?.actionItems ?? [] {
        if let owner, item.owner?.range(of: owner, options: [.caseInsensitive, .diacriticInsensitive]) == nil
        {
          continue
        }
        if item.done { done += 1 } else { open += 1 }
        if status == "all" || (status == "done") == item.done { found.append((item, meeting)) }
      }
    }
    let shown = Array(found.prefix(arguments.int("limit") ?? 100))
    var lines: [String] = []
    var lastMeeting: UUID?
    for (item, meeting) in shown {
      if meeting.id != lastMeeting {
        if lastMeeting != nil { lines.append("") }
        lines.append("\(meeting.name)  (\(friendly(meeting.startedAt)), \(Toolbox.short(meeting.id)))")
        lastMeeting = meeting.id
      }
      lines.append("  " + Toolbox.line(for: item))
    }
    if shown.isEmpty {
      lines.append(status == "open" ? "No open action items." : "No action items found.")
    } else if shown.count < found.count {
      lines.append("")
      lines.append("Showing \(shown.count) of \(found.count). Raise --limit to see more.")
    }
    return ToolOutput(
      data: [
        "open": .int(open),
        "done": .int(done),
        "returned": .int(shown.count),
        "action_items": .array(shown.map { .object(entry($0.item, in: $0.meeting)) }),
      ],
      text: lines.joined(separator: "\n")
    )
  }

  fileprivate func addAction(_ arguments: Arguments) async throws -> ToolOutput {
    var meeting = try await meeting(arguments.text("meeting"))
    try ensureEditable(meeting)
    let owner = arguments.string("owner").map(Toolbox.oneLine)
    let text = Toolbox.oneLine(arguments.text("text"))
    guard !text.isEmpty else { throw AgentError.usage("\"text\" must not be empty.") }
    guard (meeting.notes?.actionItems.count ?? 0) < Limits.actions else {
      throw AgentError.failed(
        "\"\(meeting.name)\" already has \(Limits.actions) action items, the most a meeting can hold. "
          + "Remove some first."
      )
    }
    let item = ActionItem(text: text, owner: (owner?.isEmpty ?? true) ? nil : owner)
    meeting = try await stored(
      library.updateMeeting(meeting.id) { stored in
        var notes = stored.notes ?? MeetingNotes()
        notes.actionItems.append(item)
        stored.notes = notes
      }
    )
    return ToolOutput(
      data: entry(item, in: meeting),
      text: "Added to \"\(meeting.name)\":\n  " + Toolbox.line(for: item)
    )
  }

  fileprivate func setActionDone(_ arguments: Arguments) async throws -> ToolOutput {
    let done = arguments.bool("done")
    let (item, meeting) = try await change(arguments.text("action")) { item in
      item.done = done
      return true
    }
    return ToolOutput(
      data: entry(item, in: meeting),
      text: (done ? "Done:\n  " : "Open again:\n  ") + Toolbox.line(for: item)
    )
  }

  fileprivate func updateAction(_ arguments: Arguments) async throws -> ToolOutput {
    let text = arguments.string("text").map(Toolbox.oneLine)
    let owner = arguments.string("owner").map(Toolbox.oneLine)
    guard text != nil || owner != nil else {
      throw AgentError.usage("Nothing to change. Give at least one of: text, owner.")
    }
    if let text, text.isEmpty { throw AgentError.usage("\"text\" must not be empty.") }
    let (item, meeting) = try await change(arguments.text("action")) { item in
      if let text { item.text = text }
      if let owner { item.owner = owner.isEmpty ? nil : owner }
      return true
    }
    return ToolOutput(data: entry(item, in: meeting), text: "Updated:\n  " + Toolbox.line(for: item))
  }

  fileprivate func removeAction(_ arguments: Arguments) async throws -> ToolOutput {
    let (item, meeting) = try await change(arguments.text("action")) { _ in false }
    var data = entry(item, in: meeting)
    data["removed"] = true
    return ToolOutput(data: data, text: "Removed from \"\(meeting.name)\":\n  " + Toolbox.line(for: item))
  }
}
