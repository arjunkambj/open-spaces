import Foundation
import SpacesDomain

// Daily tasks: a to-do list kept per day and sorted into categories. A task an agent adds
// is staged by default: it waits in the app until the person approves it.

extension Catalogue {
  private static let taskHelp =
    "Which task: its full ID, or the first 4 or more characters of it. Task IDs come from tasks_list."

  private static let dayHelp =
    "A day: 2026-11-24, \"today\", \"tomorrow\", \"yesterday\", or a number of days from today such as "
    + "+2 or -1."

  static let tasks: [Tool] = [
    Tool(
      path: ["tasks", "list"],
      title: "List daily tasks",
      summary: "List the daily tasks on a range of days, and the categories.",
      description:
        "Lists the user's daily tasks on the days from \"from\" through \"to\" (both today unless given), "
        + "in day order, and every task category. Each task has its ID, its text, its day, its category, "
        + "its status and who added it. Status is \"staged\" for a task an AI tool suggested that still "
        + "waits for the user's OK in the app, \"open\" for a task to do, and \"done\". Use it to answer "
        + "\"what do I have to do today?\" or \"what is planned this week?\". Action items from meetings "
        + "are not daily tasks: use actions_list for those.",
      params: [
        .text("from", "The first day. \(dayHelp)"),
        .text("to", "The last day. The same as \"from\" unless given. \(dayHelp)"),
        .choice("status", ["all", "staged", "open", "done"], "Which tasks to return.", fallback: "all"),
        .text("category", "Only tasks in this category. Case does not matter."),
        .number("limit", "The most tasks to return.", in: 1...1_000, fallback: 200),
      ],
      hints: .reads,
      example: "spaces tasks list --from today --to +6",
      run: { box, arguments in try await box.listTasks(arguments) }
    ),
    Tool(
      path: ["tasks", "add"],
      title: "Add a daily task",
      summary: "Add a task for a day. It waits for the user's OK unless staged is false.",
      description:
        "Adds a task to the user's list for one day (today unless given), in a category (the first "
        + "category unless given; tasks_list shows them all). By default the task is staged: the user "
        + "sees it in the Tasks tab of the app and approves or rejects it. Pass staged=false to put it "
        + "straight on the list, only when the user asked for this very task. Returns the task with its "
        + "new ID.",
      params: [
        .text(
          "text",
          "What needs to be done, on one line.",
          required: true,
          positional: true,
          limit: TaskList.textLimit
        ),
        .text("day", "The day the task is for. Today unless given. \(dayHelp)"),
        .text(
          "category",
          "The category. It must exist already: see tasks_list.",
          limit: TaskList.categoryLimit
        ),
        .flag(
          "staged",
          "true (the default) to let the user approve the task first; false to add it straight to the list.",
          fallback: true
        ),
      ],
      hints: .adds,
      example: "spaces tasks add \"Send the proposal\" --day tomorrow --category Gooseworks",
      run: { box, arguments in try await box.addTask(arguments) }
    ),
    Tool(
      path: ["tasks", "update"],
      title: "Change a daily task",
      summary: "Change the text, the day or the category of a task.",
      description:
        "Changes one task: its text, the day it is for (to move it to another day) or its category. Give "
        + "only what should change. To tick a task off, use tasks_set_done instead.",
      params: [
        .text("task", taskHelp, required: true, positional: true),
        .text("text", "The new text, on one line.", limit: TaskList.textLimit),
        .text("day", "The new day. \(dayHelp)"),
        .text("category", "The new category. It must exist already.", limit: TaskList.categoryLimit),
      ],
      hints: .destroys,
      aliases: [Alias(path: ["tasks", "edit"], summary: "The same as \"tasks update\".")],
      example: "spaces tasks update 3F9A01B2 --day +1",
      run: { box, arguments in try await box.updateTask(arguments) }
    ),
    Tool(
      path: ["tasks", "set-done"],
      title: "Tick a daily task off",
      summary: "Mark a task as done, or as open again.",
      description:
        "Marks one task as done. Pass done=false to mark it as open again. A staged task cannot be "
        + "ticked off: it needs the user's OK in the app first.",
      params: [
        .text("task", taskHelp, required: true, positional: true),
        .flag("done", "true to tick the task off, false to open it again.", fallback: true),
      ],
      hints: .sets,
      aliases: [
        Alias(path: ["tasks", "done"], summary: "Mark a task as done.", preset: ["done": true]),
        Alias(path: ["tasks", "reopen"], summary: "Mark a task as open again.", preset: ["done": false]),
      ],
      example: "spaces tasks done 3F9A01B2",
      run: { box, arguments in try await box.setTaskDone(arguments) }
    ),
    Tool(
      path: ["tasks", "remove"],
      title: "Remove a daily task",
      summary: "Remove a task for good.",
      description:
        "Removes one task for good. To keep a record that it was finished, use tasks_set_done instead.",
      params: [.text("task", taskHelp, required: true, positional: true)],
      hints: .destroys,
      example: "spaces tasks remove 3F9A01B2",
      run: { box, arguments in try await box.removeTask(arguments) }
    ),
    Tool(
      path: ["tasks", "add-category"],
      title: "Add a task category",
      summary: "Add a category to sort daily tasks into.",
      description:
        "Adds a new category for daily tasks, after the ones there are. Use it when the user asks for a "
        + "new category, then pass its name to tasks_add.",
      params: [
        .text(
          "name",
          "The name of the category.",
          required: true,
          positional: true,
          limit: TaskList.categoryLimit
        )
      ],
      hints: .adds,
      example: "spaces tasks add-category Home",
      run: { box, arguments in try await box.addTaskCategory(arguments) }
    ),
  ]
}

extension Toolbox {
  /// Reads a day in any of the forms in the tools' day help.
  func taskDay(from text: String, argument: String) throws -> TaskDay {
    let value = text.trimmingCharacters(in: .whitespaces).lowercased()
    let today = TaskDay.today(now)
    switch value {
    case "today": return today
    case "tomorrow": return today.adding(days: 1)
    case "yesterday": return today.adding(days: -1)
    default: break
    }
    if let offset = Int(value), (value.hasPrefix("+") || value.hasPrefix("-")), abs(offset) <= 3_650 {
      return today.adding(days: offset)
    }
    if let day = TaskDay(value) { return day }
    throw AgentError.usage(
      "\"\(argument)\" could not be read as a day: \"\(Limits.echo(text))\". Use a form like 2026-11-24, "
        + "today, tomorrow or +2."
    )
  }

  static func json(_ task: DailyTask) -> JSONObject {
    [
      "id": .string(task.id.uuidString),
      "text": .string(task.text),
      "day": .string(task.day.text),
      "category": .string(task.category),
      "status": .string(task.status.rawValue),
      "added_by": .string(task.addedBy == .agent ? "ai_tool" : "user"),
    ]
  }

  static func line(for task: DailyTask) -> String {
    let box =
      switch task.status {
      case .done: "[x]"
      case .open: "[ ]"
      case .staged: "[?]"
      }
    return "\(box) \(short(task.id))  \(task.day.text)  \(oneLine(task.category)):  \(oneLine(task.text))"
      + (task.status == .staged ? "  (waiting for the user's OK)" : "")
  }

  /// Finds one task from its ID or the start of it.
  private func task(_ reference: String, in list: TaskList) throws -> DailyTask {
    let wanted = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let found = Toolbox.matching(wanted, in: list.tasks, id: \.id) else {
      throw AgentError.usage(
        "\"\(Limits.echo(reference))\" is not a task ID. Use a full ID or the first 4 or more characters of "
          + "one. List the tasks to see their IDs."
      )
    }
    switch found.count {
    case 1: return found[0]
    case 0:
      throw AgentError.failed(
        "No task has the ID \"\(Limits.echo(reference))\". List the tasks to see their IDs."
      )
    default:
      throw AgentError.failed(
        "More than one task has an ID starting with \"\(Limits.echo(reference))\". Give more of the ID."
      )
    }
  }

  /// Finds a task by reference, applies `change` to the stored list in one step, and returns
  /// the task as it is afterwards (as it was, when the change removed it).
  private func changeTask(
    _ reference: String,
    _ change: @escaping @Sendable (inout TaskList, DailyTask.ID) throws -> Void
  ) async throws -> DailyTask {
    let before = try task(reference, in: try await library.taskList())
    let after = try await library.updateTaskList { list in try change(&list, before.id) }
    return after.task(before.id) ?? before
  }

  fileprivate func listTasks(_ arguments: Arguments) async throws -> ToolOutput {
    let from = try taskDay(from: arguments.string("from") ?? "today", argument: "from")
    let to = try arguments.string("to").map { try taskDay(from: $0, argument: "to") } ?? from
    guard from <= to else { throw AgentError.usage("\"to\" must not be before \"from\".") }
    let list = try await library.taskList()
    var category: String?
    if let name = arguments.string("category") {
      guard let found = list.category(named: name) else {
        throw AgentError.failed(
          "There is no category called \"\(Limits.echo(name))\". The categories are: "
            + list.categories.joined(separator: ", ") + "."
        )
      }
      category = found
    }
    let status = arguments.string("status") ?? "all"
    let found = list.tasks(from: from, through: to).filter { task in
      (category == nil || task.category == category) && (status == "all" || task.status.rawValue == status)
    }
    let shown = Array(found.prefix(arguments.int("limit") ?? 200))
    let range = from == to ? from.text : "\(from.text) to \(to.text)"
    var lines = ["Tasks for \(range)" + (category.map { " in \(Toolbox.oneLine($0))" } ?? "") + ":"]
    if shown.isEmpty {
      lines.append("  None.")
    } else {
      lines += shown.map { "  " + Toolbox.line(for: $0) }
      if shown.count < found.count {
        lines.append("  Showing \(shown.count) of \(found.count). Raise --limit to see more.")
      }
    }
    lines.append("")
    lines.append("Categories: " + list.categories.map(Toolbox.oneLine).joined(separator: ", "))
    return ToolOutput(
      data: [
        "from": .string(from.text),
        "to": .string(to.text),
        "categories": .strings(list.categories),
        "staged": .int(found.filter { $0.status == .staged }.count),
        "open": .int(found.filter { $0.status == .open }.count),
        "done": .int(found.filter { $0.status == .done }.count),
        "returned": .int(shown.count),
        "tasks": .array(shown.map { .object(Toolbox.json($0)) }),
      ],
      text: lines.joined(separator: "\n")
    )
  }

  fileprivate func addTask(_ arguments: Arguments) async throws -> ToolOutput {
    let text = arguments.text("text")
    let day = try arguments.string("day").map { try taskDay(from: $0, argument: "day") } ?? TaskDay.today(now)
    let category = arguments.string("category")
    let status: TaskStatus = arguments.bool("staged") ? .staged : .open
    let now = self.now
    let id = UUID()
    let list = try await library.updateTaskList { list in
      try list.add(text, day: day, category: category, status: status, addedBy: .agent, id: id, now: now)
    }
    guard let task = list.task(id) else { throw SpacesError.notFound("The new task") }
    let heading =
      status == .staged ? "Added for the user to approve in the Tasks tab:" : "Added to the user's list:"
    return ToolOutput(data: Toolbox.json(task), text: heading + "\n  " + Toolbox.line(for: task))
  }

  fileprivate func updateTask(_ arguments: Arguments) async throws -> ToolOutput {
    let text = arguments.string("text")
    let day = try arguments.string("day").map { try taskDay(from: $0, argument: "day") }
    let category = arguments.string("category")
    guard text != nil || day != nil || category != nil else {
      throw AgentError.usage("Nothing to change. Give at least one of: text, day, category.")
    }
    let task = try await changeTask(arguments.text("task")) { list, id in
      try list.edit(id, text: text, day: day, category: category)
    }
    return ToolOutput(data: Toolbox.json(task), text: "Updated:\n  " + Toolbox.line(for: task))
  }

  fileprivate func setTaskDone(_ arguments: Arguments) async throws -> ToolOutput {
    let done = arguments.bool("done")
    let task = try await changeTask(arguments.text("task")) { list, id in try list.setDone(id, done) }
    return ToolOutput(
      data: Toolbox.json(task),
      text: (done ? "Done:\n  " : "Open again:\n  ") + Toolbox.line(for: task)
    )
  }

  fileprivate func removeTask(_ arguments: Arguments) async throws -> ToolOutput {
    let task = try await changeTask(arguments.text("task")) { list, id in try list.remove(id) }
    var data = Toolbox.json(task)
    data["removed"] = true
    return ToolOutput(data: data, text: "Removed:\n  " + Toolbox.line(for: task))
  }

  fileprivate func addTaskCategory(_ arguments: Arguments) async throws -> ToolOutput {
    let name = arguments.text("name")
    let list = try await library.updateTaskList { list in _ = try list.addCategory(name) }
    return ToolOutput(
      data: ["categories": .strings(list.categories)],
      text: "Categories: " + list.categories.map(Toolbox.oneLine).joined(separator: ", ")
    )
  }
}
