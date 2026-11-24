import Foundation

// MARK: - Day

/// A day on the calendar, with no time and no time zone, written `2026-11-24`.
///
/// Tasks belong to a day, not to a moment, so a task for Tuesday stays on Tuesday wherever
/// the Mac is. Days compare in calendar order.
public struct TaskDay: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
  /// The day as `yyyy-MM-dd`.
  public let text: String

  /// Reads `yyyy-MM-dd`. `nil` for anything else, or a day the calendar does not have.
  public init?(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    // Read in UTC, which has a midnight on every day; writing it back out is the surest check.
    let utc = TaskDay.formatter(TimeZone(identifier: "UTC") ?? .current)
    guard trimmed.count == 10, let date = utc.date(from: trimmed), utc.string(from: date) == trimmed else {
      return nil
    }
    self.text = trimmed
  }

  /// The day `date` falls on in `calendar`'s time zone.
  public init(_ date: Date, calendar: Calendar = TaskDay.calendar) {
    text = TaskDay.formatter(calendar.timeZone).string(from: date)
  }

  /// The day this is on this Mac right now.
  public static func today(_ now: Date = Date()) -> TaskDay { TaskDay(now) }

  /// The first moment of the day in `calendar`'s time zone.
  public func start(calendar: Calendar = TaskDay.calendar) -> Date {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
    return calendar.startOfDay(for: calendar.date(from: components) ?? Date(timeIntervalSince1970: 0))
  }

  /// The day `count` days later (earlier when negative).
  public func adding(days count: Int) -> TaskDay {
    let calendar = TaskDay.calendar
    // Noon, so a change to or from summer time can never land on the wrong day.
    let noon = start(calendar: calendar).addingTimeInterval(12 * 3_600)
    return TaskDay(calendar.date(byAdding: .day, value: count, to: noon) ?? noon, calendar: calendar)
  }

  public var description: String { text }

  /// The day of the week, 1 for Sunday through 7 for Saturday.
  public var weekday: Int {
    let calendar = TaskDay.calendar
    return calendar.component(.weekday, from: start(calendar: calendar).addingTimeInterval(12 * 3_600))
  }

  public static func < (a: TaskDay, b: TaskDay) -> Bool { a.text < b.text }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let day = TaskDay(raw) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a day: \(raw)")
    }
    self = day
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(text)
  }

  /// The Gregorian calendar in this Mac's time zone.
  public static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
  }

  private static func formatter(_ zone: TimeZone) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = zone
    formatter.isLenient = false
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }
}

// MARK: - Task

/// Where a task is on its way to done.
public enum TaskStatus: String, Codable, Sendable, CaseIterable {
  /// Suggested by an AI tool. It waits for the person's OK before it counts as a task.
  case staged
  case open
  case done
}

/// How often a task comes back once it is ticked off.
public enum TaskRepeat: String, Codable, Sendable, CaseIterable {
  case daily
  /// Monday to Friday.
  case weekdays
  /// The same day of the week.
  case weekly

  /// The first day after `day` the task is due again, and not before `earliest`.
  public func next(after day: TaskDay, notBefore earliest: TaskDay) -> TaskDay {
    let step = self == .weekly ? 7 : 1
    var candidate = day.adding(days: step)
    // Ten years of steps at most, so a task from long ago can never keep this busy.
    for _ in 0..<3_650 {
      let due = self != .weekdays || !(candidate.weekday == 1 || candidate.weekday == 7)
      if due && candidate >= earliest { return candidate }
      candidate = candidate.adding(days: step)
    }
    return candidate
  }
}

/// Who put a task on the list.
public enum TaskAuthor: String, Codable, Sendable {
  /// The person, in the app.
  case me
  /// An AI tool, through the `spaces` tool.
  case agent
}

/// One thing to do on one day.
public struct DailyTask: Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  /// One line of plain text.
  public var text: String
  public var day: TaskDay
  /// The name of one of `TaskList.categories`.
  public var category: String
  public var status: TaskStatus
  public var addedBy: TaskAuthor
  /// The AI tool that added the task, as it names itself (`claude-code`), when it gave a name.
  public var agent: String?
  public var createdAt: Date
  /// Where the task sits among the tasks of its day, lowest first. Tasks with none come after
  /// the others, oldest first. Set when the person drags tasks into an order.
  public var rank: Int?
  /// How often the task comes back. `nil` for a task done once.
  public var repeats: TaskRepeat?
  /// The next one of a repeating task, made when this one was ticked off.
  public var repeatedAs: UUID?
  /// More about the task, in plain text or Markdown. Several lines are fine.
  public var notes: String?
  /// The meeting the task came from or belongs to.
  public var meeting: Meeting.ID?

  public init(
    id: UUID = UUID(),
    text: String,
    day: TaskDay,
    category: String,
    status: TaskStatus = .open,
    addedBy: TaskAuthor = .me,
    agent: String? = nil,
    createdAt: Date = Date(),
    rank: Int? = nil,
    repeats: TaskRepeat? = nil,
    repeatedAs: UUID? = nil,
    notes: String? = nil,
    meeting: Meeting.ID? = nil
  ) {
    self.id = id
    self.text = text
    self.day = day
    self.category = category
    self.status = status
    self.addedBy = addedBy
    self.agent = agent
    self.createdAt = createdAt
    self.rank = rank
    self.repeats = repeats
    self.repeatedAs = repeatedAs
    self.notes = notes
    self.meeting = meeting
  }

  public var isDone: Bool { status == .done }

  /// The order of tasks on one day: by `rank`, then oldest first.
  public static func dayOrder(_ a: DailyTask, _ b: DailyTask) -> Bool {
    (a.rank ?? Int.max, a.createdAt) < (b.rank ?? Int.max, b.createdAt)
  }
}

// MARK: - List

/// Every daily task and the categories they are sorted into. Stored as one file, so a change
/// to a category and to its tasks is made in one step.
///
/// The methods here hold the rules, for the app and for agents alike: text is one line, a
/// category name is used once, every task is in a category that exists, and the first
/// category is where new tasks go unless another is named. A broken rule throws
/// `SpacesError.invalidInput` with a message for people.
public struct TaskList: Codable, Sendable, Hashable {
  /// In the order people see them. Never empty: a file with none does not load, and the last
  /// one cannot be removed.
  public var categories: [String]
  public var tasks: [DailyTask]

  /// The categories a new list starts with.
  public static let startingCategories = ["General", "Gooseworks"]
  /// The most characters a task's text may have.
  public static let textLimit = 500
  /// The most characters a task's notes may have.
  public static let notesLimit = 5_000
  /// The most characters a category name may have.
  public static let categoryLimit = 40
  /// The most categories and tasks the list holds.
  public static let mostCategories = 30
  public static let mostTasks = 5_000

  public init(categories: [String] = TaskList.startingCategories, tasks: [DailyTask] = []) {
    self.categories = categories
    self.tasks = tasks
  }

  private enum CodingKeys: String, CodingKey { case categories, tasks }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    // A missing key gets its default, as everywhere in the data folder.
    categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? TaskList.startingCategories
    guard !categories.isEmpty else {
      throw DecodingError.dataCorruptedError(
        forKey: .categories,
        in: c,
        debugDescription: "A task list needs at least one category."
      )
    }
    tasks = try c.decodeIfPresent([DailyTask].self, forKey: .tasks) ?? []
  }

  /// Where a new task goes when no category is named.
  public var defaultCategory: String { categories[0] }

  /// The stored name of a category, matched without regard to case. `nil` when there is none.
  public func category(named name: String) -> String? {
    let wanted = TaskList.oneLine(name)
    return categories.first { $0.compare(wanted, options: [.caseInsensitive]) == .orderedSame }
  }

  public func task(_ id: DailyTask.ID) -> DailyTask? { tasks.first { $0.id == id } }

  /// Tasks on the days from `first` through `last`, in day order, then in each day's order.
  public func tasks(from first: TaskDay, through last: TaskDay) -> [DailyTask] {
    tasks.filter { $0.day >= first && $0.day <= last }.sorted(by: TaskList.order)
  }

  /// Tasks waiting for the person's OK, in day order.
  public var staged: [DailyTask] { tasks.filter { $0.status == .staged }.sorted(by: TaskList.order) }

  // MARK: Tasks

  /// Adds a task and returns it. `category` `nil` means `defaultCategory`.
  @discardableResult
  public mutating func add(
    _ text: String,
    day: TaskDay,
    category: String? = nil,
    status: TaskStatus = .open,
    addedBy: TaskAuthor = .me,
    agent: String? = nil,
    repeats: TaskRepeat? = nil,
    notes: String? = nil,
    meeting: Meeting.ID? = nil,
    id: UUID = UUID(),
    now: Date = Date()
  ) throws -> DailyTask {
    guard tasks.count < TaskList.mostTasks else {
      throw SpacesError.invalidInput(
        "There are already \(TaskList.mostTasks) tasks, the most Spaces keeps. Delete some old ones first."
      )
    }
    let task = DailyTask(
      id: id,
      text: try TaskList.checkedText(text),
      day: day,
      category: try existing(category ?? defaultCategory),
      status: status,
      addedBy: addedBy,
      agent: agent.map(TaskList.oneLine).flatMap { $0.isEmpty ? nil : String($0.prefix(80)) },
      createdAt: now,
      repeats: repeats,
      notes: try TaskList.checkedNotes(notes),
      meeting: meeting
    )
    tasks.append(task)
    return task
  }

  /// Changes one task and returns it as it is afterwards. Only what is given changes. A task
  /// moved to another day goes to the end of that day. `.some(nil)` clears `repeats`, `notes` or
  /// `meeting`.
  @discardableResult
  public mutating func edit(
    _ id: DailyTask.ID,
    text: String? = nil,
    day: TaskDay? = nil,
    category: String? = nil,
    repeats: TaskRepeat?? = nil,
    notes: String?? = nil,
    meeting: Meeting.ID?? = nil
  ) throws -> DailyTask {
    let index = try position(of: id)
    if let text { tasks[index].text = try TaskList.checkedText(text) }
    if let day, day != tasks[index].day {
      tasks[index].day = day
      tasks[index].rank = nil
    }
    if let category { tasks[index].category = try existing(category) }
    if let repeats { tasks[index].repeats = repeats }
    if let notes { tasks[index].notes = try TaskList.checkedNotes(notes) }
    if let meeting { tasks[index].meeting = meeting }
    return tasks[index]
  }

  /// Moves a task to `day`, just before `other` (a task on that day), or to the end of the day
  /// when `other` is `nil` or not on that day. The tasks of that day are numbered again in their
  /// new order.
  @discardableResult
  public mutating func move(_ id: DailyTask.ID, to day: TaskDay, before other: DailyTask.ID?) throws
    -> DailyTask
  {
    let index = try position(of: id)
    tasks[index].day = day
    var order = tasks.filter { $0.day == day && $0.id != id }.sorted(by: DailyTask.dayOrder).map(\.id)
    order.insert(id, at: order.firstIndex { $0 == other } ?? order.endIndex)
    for (rank, taskID) in order.enumerated() {
      if let at = tasks.firstIndex(where: { $0.id == taskID }) { tasks[at].rank = rank }
    }
    return tasks[index]
  }

  /// Ticks a task off, or opens it again. A staged task needs the person's OK first.
  ///
  /// Ticking off a repeating task adds the next one, with the same text, category, notes and
  /// meeting, on the first day it is due after this
  /// one's day and not before `today`, unless the next one is still there from an earlier tick.
  /// Opening a task again changes nothing else: the next one stays.
  @discardableResult
  public mutating func setDone(_ id: DailyTask.ID, _ done: Bool, today: TaskDay = .today()) throws
    -> DailyTask
  {
    let index = try position(of: id)
    let task = tasks[index]
    guard task.status != .staged else {
      throw SpacesError.invalidInput(
        "This task still waits for approval in the Tasks tab of Spaces, so it cannot be ticked off yet."
      )
    }
    let needsNext = done && task.repeats != nil && (task.repeatedAs.flatMap { self.task($0) } == nil)
    if needsNext && tasks.count >= TaskList.mostTasks {
      throw SpacesError.invalidInput(
        "There are already \(TaskList.mostTasks) tasks, so the next one of this repeating task cannot be "
          + "added. Delete some old tasks first."
      )
    }
    tasks[index].status = done ? .done : .open
    if needsNext, let repeats = task.repeats {
      let next = DailyTask(
        text: task.text,
        day: repeats.next(after: task.day, notBefore: today),
        category: task.category,
        addedBy: task.addedBy,
        agent: task.agent,
        repeats: repeats,
        notes: task.notes,
        meeting: task.meeting
      )
      tasks.append(next)
      tasks[index].repeatedAs = next.id
    }
    return tasks[index]
  }

  /// Puts staged tasks on the list as open tasks. Tasks that are not staged are left alone.
  public mutating func approve(_ ids: Set<DailyTask.ID>) {
    for index in tasks.indices where ids.contains(tasks[index].id) && tasks[index].status == .staged {
      tasks[index].status = .open
    }
  }

  /// Deletes a task and returns it.
  @discardableResult
  public mutating func remove(_ id: DailyTask.ID) throws -> DailyTask {
    tasks.remove(at: try position(of: id))
  }

  // MARK: Categories

  /// Adds a category at the end and returns its name as stored.
  @discardableResult
  public mutating func addCategory(_ name: String) throws -> String {
    let clean = try TaskList.checkedCategory(name)
    if let taken = category(named: clean) {
      throw SpacesError.invalidInput("There is already a category called “\(taken)”.")
    }
    guard categories.count < TaskList.mostCategories else {
      throw SpacesError.invalidInput("You can have up to \(TaskList.mostCategories) categories.")
    }
    categories.append(clean)
    return clean
  }

  /// Renames a category, and moves its tasks with it.
  public mutating func renameCategory(_ old: String, to new: String) throws {
    let from = try existing(old)
    let clean = try TaskList.checkedCategory(new)
    if let taken = category(named: clean), taken != from {
      throw SpacesError.invalidInput("There is already a category called “\(taken)”.")
    }
    categories = categories.map { $0 == from ? clean : $0 }
    for index in tasks.indices where tasks[index].category == from { tasks[index].category = clean }
  }

  /// Deletes a category. Its tasks move to the first category that is left. The last
  /// category cannot be deleted.
  public mutating func removeCategory(_ name: String) throws {
    let doomed = try existing(name)
    guard categories.count > 1 else {
      throw SpacesError.invalidInput("You need at least one category, so the last one cannot be deleted.")
    }
    categories.removeAll { $0 == doomed }
    let home = defaultCategory
    for index in tasks.indices where tasks[index].category == doomed { tasks[index].category = home }
  }

  // MARK: Inside

  private static func order(_ a: DailyTask, _ b: DailyTask) -> Bool {
    a.day == b.day ? DailyTask.dayOrder(a, b) : a.day < b.day
  }

  private func position(of id: DailyTask.ID) throws -> Int {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw SpacesError.notFound("The task") }
    return index
  }

  private func existing(_ name: String) throws -> String {
    guard let found = category(named: name) else {
      throw SpacesError.invalidInput(
        "There is no category called “\(TaskList.oneLine(name))”. The categories are: "
          + categories.joined(separator: ", ") + "."
      )
    }
    return found
  }

  private static func checkedText(_ text: String) throws -> String {
    let clean = oneLine(text)
    guard !clean.isEmpty else { throw SpacesError.invalidInput("Write what the task is.") }
    guard clean.count <= textLimit else {
      throw SpacesError.invalidInput("A task can be at most \(textLimit) characters.")
    }
    return clean
  }

  /// Notes as stored: trimmed, and `nil` when nothing is left.
  private static func checkedNotes(_ notes: String?) throws -> String? {
    guard let clean = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else {
      return nil
    }
    guard clean.count <= notesLimit else {
      throw SpacesError.invalidInput("A task's notes can be at most \(notesLimit) characters.")
    }
    return clean
  }

  private static func checkedCategory(_ name: String) throws -> String {
    let clean = oneLine(name)
    guard !clean.isEmpty else { throw SpacesError.invalidInput("Give the category a name.") }
    guard clean.count <= categoryLimit else {
      throw SpacesError.invalidInput("A category name can be at most \(categoryLimit) characters.")
    }
    return clean
  }

  /// One line: line breaks, tabs and other control characters become spaces, runs of spaces
  /// become one, and the ends are trimmed.
  private static func oneLine(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      let category = scalar.properties.generalCategory
      let hidden =
        category == .control || category == .lineSeparator || category == .paragraphSeparator
        || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
      scalars.append(hidden ? " " : scalar)
    }
    return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
