import Foundation
import SpacesDomain

/// The days the Tasks screen shows.
enum TaskRange: String, CaseIterable, Identifiable, Hashable {
  case today, tomorrow, thisWeek, nextWeek, lastWeek, pick

  var id: String { rawValue }

  var title: String {
    switch self {
    case .today: "Today"
    case .tomorrow: "Tomorrow"
    case .thisWeek: "This week"
    case .nextWeek: "Next 7 days"
    case .lastWeek: "Last 7 days"
    case .pick: "Pick dates…"
    }
  }

  /// The first and last day, both included. `picked` is used for `.pick`, put in order.
  func days(today: TaskDay, picked: (TaskDay, TaskDay), calendar: Calendar = .current) -> ClosedRange<TaskDay>
  {
    switch self {
    case .today: return today...today
    case .tomorrow: return today.adding(days: 1)...today.adding(days: 1)
    case .thisWeek:
      // The week as this Mac counts it: Monday or Sunday first, by the region's custom.
      var calendar = calendar
      calendar.timeZone = .current
      let noon = today.start(calendar: calendar).addingTimeInterval(12 * 3_600)
      let weekday = calendar.component(.weekday, from: noon)
      let back = (weekday - calendar.firstWeekday + 7) % 7
      let first = today.adding(days: -back)
      return first...first.adding(days: 6)
    case .nextWeek: return today...today.adding(days: 6)
    case .lastWeek: return today.adding(days: -6)...today
    case .pick: return min(picked.0, picked.1)...max(picked.0, picked.1)
    }
  }
}

/// One line on the Tasks screen: a daily task, or an action item from a meeting.
enum TaskEntry: Identifiable, Hashable {
  case task(DailyTask)
  case action(ActionItem, meeting: Meeting.ID, meetingTitle: String)

  var id: UUID {
    switch self {
    case .task(let task): task.id
    case .action(let item, _, _): item.id
    }
  }

  var text: String {
    switch self {
    case .task(let task): task.text
    case .action(let item, _, _): item.text
    }
  }

  var isDone: Bool {
    switch self {
    case .task(let task): task.isDone
    case .action(let item, _, _): item.done
    }
  }
}

/// What the Tasks screen shows for a range of days and a category.
struct TaskBoard {
  struct DaySection: Identifiable {
    var day: TaskDay
    var entries: [TaskEntry]
    var id: String { day.text }
  }

  /// Tasks an AI tool suggested, waiting for the person's OK, on any day.
  var waiting: [DailyTask] = []
  /// Things not done from days before the range. Only when the range takes in today.
  var earlier: [(day: TaskDay, entry: TaskEntry)] = []
  /// The days of the range that have something on them, in order.
  var days: [DaySection] = []

  var isEmpty: Bool { waiting.isEmpty && earlier.isEmpty && days.isEmpty }
}

enum TasksLogic {
  /// Sorts tasks and meeting action items onto days.
  ///
  /// - category: only tasks in this category, and no meeting action items. `nil` for everything.
  static func board(
    list: TaskList,
    meetings: [Meeting],
    days: ClosedRange<TaskDay>,
    today: TaskDay,
    category: String?
  ) -> TaskBoard {
    var dated: [(day: TaskDay, entry: TaskEntry)] = []
    var waiting: [DailyTask] = []
    for task in list.tasks where category == nil || task.category == category {
      if task.status == .staged {
        waiting.append(task)
      } else {
        dated.append((task.day, .task(task)))
      }
    }
    if category == nil {
      for meeting in meetings {
        let day = TaskDay(meeting.startedAt)
        for item in meeting.notes?.actionItems ?? [] {
          dated.append((day, .action(item, meeting: meeting.id, meetingTitle: meeting.title)))
        }
      }
    }
    var board = TaskBoard()
    board.waiting = waiting.sorted { ($0.day, $0.createdAt) < ($1.day, $1.createdAt) }
    if days.contains(today) {
      board.earlier = dated.filter { $0.day < days.lowerBound && !$0.entry.isDone }
        .sorted { $0.day < $1.day }
    }
    let inRange = Dictionary(grouping: dated.filter { days.contains($0.day) }, by: \.day)
    board.days = inRange.keys.sorted().map { day in
      TaskBoard.DaySection(day: day, entries: ordered(inRange[day]?.map(\.entry) ?? []))
    }
    return board
  }

  /// Not done first, tasks before meeting action items, and otherwise the order they were made in.
  private static func ordered(_ entries: [TaskEntry]) -> [TaskEntry] {
    func rank(_ entry: TaskEntry) -> Int {
      switch entry {
      case .task: entry.isDone ? 2 : 0
      case .action: entry.isDone ? 3 : 1
      }
    }
    func made(_ entry: TaskEntry) -> Date {
      if case .task(let task) = entry { return task.createdAt }
      return .distantPast
    }
    return entries.enumerated().sorted { a, b in
      (rank(a.element), made(a.element), a.offset) < (rank(b.element), made(b.element), b.offset)
    }.map(\.element)
  }

  /// "Today", "Tomorrow", "Yesterday", or the weekday and date: "Thursday 26 November".
  static func title(_ day: TaskDay, today: TaskDay) -> String {
    if day == today { return "Today" }
    if day == today.adding(days: 1) { return "Tomorrow" }
    if day == today.adding(days: -1) { return "Yesterday" }
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.setLocalizedDateFormatFromTemplate(
      day.text.prefix(4) == today.text.prefix(4) ? "EEEEdMMMM" : "EEEEdMMMMyyyy"
    )
    return formatter.string(from: day.start().addingTimeInterval(12 * 3_600))
  }

  /// The day as it is written inside a sentence: "today", "tomorrow", or "Thursday 26 November".
  static func inSentence(_ day: TaskDay, today: TaskDay) -> String {
    let title = title(day, today: today)
    let near = [today.adding(days: -1), today, today.adding(days: 1)]
    return near.contains(day) ? title.lowercased() : title
  }

  /// "3 to-dos, 1 done".
  static func count(_ entries: [TaskEntry]) -> String {
    let done = entries.filter(\.isDone).count
    let total = entries.count == 1 ? "1 to-do" : "\(entries.count) to-dos"
    return done == 0 ? total : "\(total), \(done) done"
  }
}
