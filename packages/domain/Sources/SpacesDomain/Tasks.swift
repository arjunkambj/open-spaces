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
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    text: String,
    day: TaskDay,
    category: String,
    status: TaskStatus = .open,
    addedBy: TaskAuthor = .me,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.text = text
    self.day = day
    self.category = category
    self.status = status
    self.addedBy = addedBy
    self.createdAt = createdAt
  }

  public var isDone: Bool { status == .done }
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
  /// In the order people see them. Never empty once the list has been changed through here.
  public var categories: [String]
  public var tasks: [DailyTask]

  /// The categories a new list starts with.
  public static let startingCategories = ["General", "Gooseworks"]
  /// The most characters a task's text may have.
  public static let textLimit = 500
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
    categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? TaskList.startingCategories
    tasks = try c.decodeIfPresent([DailyTask].self, forKey: .tasks) ?? []
  }

  /// Where a new task goes when no category is named.
  public var defaultCategory: String { categories.first ?? TaskList.startingCategories[0] }

  /// The stored name of a category, matched without regard to case. `nil` when there is none.
  public func category(named name: String) -> String? {
    let wanted = TaskList.oneLine(name)
    return categories.first { $0.compare(wanted, options: [.caseInsensitive]) == .orderedSame }
  }

  public func task(_ id: DailyTask.ID) -> DailyTask? { tasks.first { $0.id == id } }

  /// Tasks on the days from `first` through `last`, in day order, then oldest first.
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
      createdAt: now
    )
    tasks.append(task)
    return task
  }

  /// Changes one task and returns it as it is afterwards. Only what is given changes.
  @discardableResult
  public mutating func edit(
    _ id: DailyTask.ID,
    text: String? = nil,
    day: TaskDay? = nil,
    category: String? = nil
  ) throws -> DailyTask {
    let index = try position(of: id)
    if let text { tasks[index].text = try TaskList.checkedText(text) }
    if let day { tasks[index].day = day }
    if let category { tasks[index].category = try existing(category) }
    return tasks[index]
  }

  /// Ticks a task off, or opens it again. A staged task needs the person's OK first.
  @discardableResult
  public mutating func setDone(_ id: DailyTask.ID, _ done: Bool) throws -> DailyTask {
    let index = try position(of: id)
    guard tasks[index].status != .staged else {
      throw SpacesError.invalidInput(
        "This task still waits for approval in the Tasks tab of Spaces, so it cannot be ticked off yet."
      )
    }
    tasks[index].status = done ? .done : .open
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
    guard category(named: clean) == nil else {
      throw SpacesError.invalidInput("There is already a category called “\(clean)”.")
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
    (a.day, a.createdAt) < (b.day, b.createdAt)
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
