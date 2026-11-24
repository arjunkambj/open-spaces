import SpacesDomain
import SpacesEngine
import SwiftUI

/// How the board sorts tasks into columns.
enum TaskBoardGrouping: String, CaseIterable, Identifiable, Hashable {
  case day, category, status

  var id: String { rawValue }

  var title: String {
    switch self {
    case .day: "Day"
    case .category: "Category"
    case .status: "Status"
    }
  }
}

/// Daily tasks as cards in columns. Dragging a card to another column changes its day,
/// its category or its status.
struct TasksBoard: View {
  private let list: TaskList
  private let meetings: [Meeting]
  private let days: ClosedRange<TaskDay>
  private let today: TaskDay
  private let category: String?
  private let grouping: TaskBoardGrouping
  private let onOpen: (DailyTask) -> Void
  private let onToggle: (DailyTask) -> Void
  private let onChange: (String?, @escaping @Sendable (inout TaskList) throws -> Void) -> Void

  /// - meetings: for the title of a task's linked meeting.
  /// - days: the days shown. When they take in `today`, tasks not done from before them show too.
  /// - category: only tasks in this category. `nil` for all of them.
  /// - onOpen: a card was clicked.
  /// - onToggle: a card's tick box was clicked.
  /// - onChange: saves a change to the list, then shows the message, when there is one.
  init(
    list: TaskList,
    meetings: [Meeting],
    days: ClosedRange<TaskDay>,
    today: TaskDay,
    category: String?,
    grouping: TaskBoardGrouping,
    onOpen: @escaping (DailyTask) -> Void,
    onToggle: @escaping (DailyTask) -> Void,
    onChange: @escaping (String?, @escaping @Sendable (inout TaskList) throws -> Void) -> Void
  ) {
    self.list = list
    self.meetings = meetings
    self.days = days
    self.today = today
    self.category = category
    self.grouping = grouping
    self.onOpen = onOpen
    self.onToggle = onToggle
    self.onChange = onChange
  }

  var body: some View {
    let columns = TaskBoardColumns.make(
      list: list,
      days: days,
      today: today,
      category: category,
      grouping: grouping
    )
    ScrollView(.horizontal) {
      HStack(alignment: .top, spacing: Spaces.Space.m) {
        ForEach(columns) { column in
          BoardColumnView(column: column, onDrop: { drop($0, on: column.target, before: nil) }) {
            ForEach(column.tasks) { task in
              card(task, in: column, columns: columns)
            }
          }
        }
      }
      // Every column as tall as the tallest, so a card can be dropped anywhere below the last one.
      .fixedSize(horizontal: false, vertical: true)
      .padding(.bottom, Spaces.Space.s)
    }
    .scrollIndicators(.automatic)
  }

  // MARK: - Cards

  private func card(_ task: DailyTask, in column: TaskBoardColumn, columns: [TaskBoardColumn]) -> some View {
    // In a day, a card dropped on an open task lands just above it; done tasks come after the
    // open ones, so a card dropped on one of them goes to the end of the day.
    let before: DailyTask.ID? = task.isDone ? nil : task.id
    let takesDrops = if case .day = column.target { true } else { false }
    return BoardCard(
      task: task,
      caption: caption(task, in: column),
      onOpen: { onOpen(task) },
      onToggle: { onToggle(task) }
    )
    .draggable(TaskDragItem(id: task.id)) {
      Text(task.text)
        .spacesText(.body)
        .lineLimit(1)
        .padding(.horizontal, Spaces.Space.m)
        .padding(.vertical, Spaces.Space.s)
        .background(Spaces.Color.raised, in: RoundedRectangle(cornerRadius: Spaces.Radius.control))
    }
    .modifier(CardDrop(isEnabled: takesDrops) { drop($0, on: column.target, before: before) })
    .accessibilityActions { moveActions(task, in: column, columns: columns) }
  }

  /// "Suggested by Claude Code · Tomorrow · Gooseworks · Every weekday · Meeting “Weekly sync”".
  private func caption(_ task: DailyTask, in column: TaskBoardColumn) -> String? {
    var parts: [String] = []
    if task.status == .staged {
      let tool = task.agent.map { AgentStatus.name(of: AgentClient(name: $0)) } ?? "an AI tool"
      parts.append("Suggested by \(tool)")
    }
    let inDay = if case .day = column.target { true } else { false }
    if !inDay { parts.append(TasksLogic.title(task.day, today: today)) }
    if grouping != .category && category == nil { parts.append(task.category) }
    if let repeats = task.repeats { parts.append(TasksLogic.repeatTitle(repeats)) }
    if let id = task.meeting, let meeting = meetings.first(where: { $0.id == id }) {
      parts.append("Meeting “\(meeting.title)”")
    }
    // A no-break space before each dot, so a line never starts with one.
    return parts.isEmpty ? nil : parts.joined(separator: TaskBoardCaption.separator)
  }

  /// What VoiceOver offers in place of a drag.
  @ViewBuilder
  private func moveActions(_ task: DailyTask, in column: TaskBoardColumn, columns: [TaskBoardColumn])
    -> some View
  {
    if case .day(let day) = column.target, !task.isDone {
      let open = column.tasks.filter { !$0.isDone }.map(\.id)
      if let index = open.firstIndex(of: task.id) {
        if index > 0 {
          Button("Move up") { apply(task, to: .day(day), before: open[index - 1]) }
        }
        if index < open.count - 1 {
          Button("Move down") {
            apply(task, to: .day(day), before: index + 2 < open.count ? open[index + 2] : nil)
          }
        }
      }
    }
    ForEach(columns.filter { $0.id != column.id && plan(task, to: $0.target, before: nil) != nil }) { other in
      Button("Move to \(other.title)") { apply(task, to: other.target, before: nil) }
    }
  }

  // MARK: - Changes

  /// Handles a card dropped on a column, or on a card in it: `before` is that card.
  /// Returns false for anything that is not one of the tasks, or a drop that changes nothing.
  private func drop(_ items: [TaskDragItem], on target: TaskBoardColumn.Target, before: DailyTask.ID?) -> Bool
  {
    guard let id = items.first?.id, id != before, let task = list.task(id) else { return false }
    return apply(task, to: target, before: before)
  }

  @discardableResult
  private func apply(_ task: DailyTask, to target: TaskBoardColumn.Target, before: DailyTask.ID?) -> Bool {
    guard let plan = plan(task, to: target, before: before) else { return false }
    onChange(plan.message, plan.work)
    return true
  }

  private struct Plan {
    var message: String?
    var work: @Sendable (inout TaskList) throws -> Void
  }

  /// The change that puts `task` in a column, or `nil` when it would change nothing.
  private func plan(_ task: DailyTask, to target: TaskBoardColumn.Target, before: DailyTask.ID?) -> Plan? {
    let id = task.id
    let today = self.today
    switch target {
    case .earlier, .waiting:
      return nil
    case .day(let day):
      // Done tasks are shown after the open ones, so a done task always goes to the end of the day.
      let before = task.isDone ? nil : before
      if task.day == day {
        // The same day: a change only when the order of the day changes.
        var moved = list
        guard (try? moved.move(id, to: day, before: before)) != nil,
          moved.tasks(from: day, through: day).map(\.id) != list.tasks(from: day, through: day).map(\.id)
        else { return nil }
        return Plan(message: nil) { try $0.move(id, to: day, before: before) }
      }
      return Plan(message: "Moved to \(TasksLogic.inSentence(day, today: today))") {
        try $0.move(id, to: day, before: before)
      }
    case .category(let name):
      guard task.category != name else { return nil }
      return Plan(message: "Moved to \(name)") { try $0.edit(id, category: name) }
    case .open:
      switch task.status {
      case .open: return nil
      case .staged: return Plan(message: "Added to your list") { $0.approve([id]) }
      case .done: return Plan(message: nil) { try $0.setDone(id, false, today: today) }
      }
    case .done:
      if task.status == .done { return nil }
      var message: String?
      if let repeats = task.repeats, task.repeatedAs == nil {
        let next = repeats.next(after: task.day, notBefore: today)
        message = "Done. The next one is on \(TasksLogic.inSentence(next, today: today))."
      } else if task.status == .staged {
        message = "Added to your list as done"
      }
      return Plan(message: message) { list in
        list.approve([id])
        try list.setDone(id, true, today: today)
      }
    }
  }
}

// MARK: - Columns

enum TaskBoardCaption {
  /// Between the parts of a card's caption line.
  static let separator = "\u{00A0}· "
}

/// One column of the board.
struct TaskBoardColumn: Identifiable {
  /// What a column stands for, and so what a card dropped on it changes.
  enum Target: Hashable {
    /// Tasks not done from days before the ones shown. Takes no drops.
    case earlier
    case day(TaskDay)
    case category(String)
    /// Tasks an AI tool suggested. Takes no drops.
    case waiting
    case open
    case done
  }

  var target: Target
  var title: String
  var tasks: [DailyTask]
  var id: Target { target }
}

/// Sorts tasks into the columns of the board.
enum TaskBoardColumns {
  static func make(
    list: TaskList,
    days: ClosedRange<TaskDay>,
    today: TaskDay,
    category: String?,
    grouping: TaskBoardGrouping
  ) -> [TaskBoardColumn] {
    let mine = list.tasks.filter { category == nil || $0.category == category }
    let staged = mine.filter { $0.status == .staged }.sorted {
      ($0.day, $0.createdAt) < ($1.day, $1.createdAt)
    }
    let listed = mine.filter { $0.status != .staged }
    let inRange = listed.filter { days.contains($0.day) }
    let earlier =
      days.contains(today)
      ? listed.filter { $0.day < days.lowerBound && !$0.isDone }.sorted(by: inDayOrder) : []

    switch grouping {
    case .day:
      var columns: [TaskBoardColumn] = []
      if !earlier.isEmpty {
        columns.append(TaskBoardColumn(target: .earlier, title: "Not done from earlier", tasks: earlier))
      }
      let byDay = Dictionary(grouping: inRange, by: \.day)
      for day in shownDays(days, withTasks: Set(byDay.keys)) {
        let tasks = (byDay[day] ?? []).sorted { a, b in
          a.isDone != b.isDone ? !a.isDone : DailyTask.dayOrder(a, b)
        }
        columns.append(
          TaskBoardColumn(target: .day(day), title: TasksLogic.title(day, today: today), tasks: tasks)
        )
      }
      return columns
    case .category:
      let tasks = (earlier + inRange).sorted { a, b in a.isDone != b.isDone ? !a.isDone : inDayOrder(a, b) }
      // Categories in their order, then any a task names that the list does not (a hand-edited
      // file), so no task is left out of the board.
      let known = list.categories + tasks.map(\.category).filter { !list.categories.contains($0) }
      var seen = Set<String>()
      let all = known.filter { seen.insert($0).inserted }
      let names = category.map { name in all.filter { $0 == name } } ?? all
      return names.map { name in
        TaskBoardColumn(target: .category(name), title: name, tasks: tasks.filter { $0.category == name })
      }
    case .status:
      let tasks = (earlier + inRange).sorted(by: inDayOrder)
      return [
        TaskBoardColumn(target: .waiting, title: "Waiting for your OK", tasks: staged),
        TaskBoardColumn(target: .open, title: "To do", tasks: tasks.filter { !$0.isDone }),
        TaskBoardColumn(target: .done, title: "Done", tasks: tasks.filter(\.isDone)),
      ]
    }
  }

  /// Every day of a range of up to `TasksLogic.everyDayUpTo` days, empty or not, so a card can
  /// be dropped on it. In a longer range, only the days with tasks.
  private static func shownDays(_ days: ClosedRange<TaskDay>, withTasks: Set<TaskDay>) -> [TaskDay] {
    var all: [TaskDay] = []
    var day = days.lowerBound
    while day <= days.upperBound && all.count < TasksLogic.everyDayUpTo {
      all.append(day)
      day = day.adding(days: 1)
    }
    return day <= days.upperBound ? withTasks.sorted() : all
  }

  /// By day, then in each day's own order.
  private static func inDayOrder(_ a: DailyTask, _ b: DailyTask) -> Bool {
    a.day == b.day ? DailyTask.dayOrder(a, b) : a.day < b.day
  }
}

// MARK: - Parts

/// A column: its title and count, then its cards, on a soft fill that darkens while a card is
/// dragged over it.
private struct BoardColumnView<Cards: View>: View {
  let column: TaskBoardColumn
  let onDrop: ([TaskDragItem]) -> Bool
  @ViewBuilder let cards: Cards

  @State private var isTargeted = false

  static var width: CGFloat { 280 }
  /// An empty column is still this tall, so a card can be dropped on it.
  static var minHeight: CGFloat { 160 }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Spaces.Radius.card, style: .continuous)
    VStack(alignment: .leading, spacing: Spaces.Space.s) {
      header
      if column.tasks.isEmpty {
        Text("Nothing here")
          .spacesText(.caption, color: Spaces.Color.textTertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Spaces.Space.xs)
          .padding(.vertical, Spaces.Space.s)
      } else {
        cards
      }
    }
    .padding(Spaces.Space.s)
    .frame(width: Self.width, alignment: .topLeading)
    .frame(minHeight: Self.minHeight, maxHeight: .infinity, alignment: .top)
    .background(isTargeted ? Spaces.Color.surfaceSelected : Spaces.Color.surface, in: shape)
    .overlay {
      if isTargeted {
        shape.strokeBorder(Spaces.Color.borderStrong, lineWidth: Spaces.Stroke.hairline)
          .accessibilityHidden(true)
      }
    }
    .modifier(ColumnDrop(isEnabled: takesDrops, isTargeted: $isTargeted, onDrop: onDrop))
    .animation(Spaces.Motion.quick, value: isTargeted)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(column.title), \(count)")
  }

  private var takesDrops: Bool { column.target != .earlier && column.target != .waiting }

  private var count: String { column.tasks.count == 1 ? "1 task" : "\(column.tasks.count) tasks" }

  private var header: some View {
    HStack(spacing: Spaces.Space.s) {
      Text(column.title)
        .spacesText(.bodyStrong)
        .lineLimit(1)
      Text("\(column.tasks.count)")
        .spacesText(.caption, color: Spaces.Color.textTertiary)
        .monospacedDigit()
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spaces.Space.xs)
    .padding(.vertical, Spaces.Space.xs)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(column.title), \(count)")
    .accessibilityAddTraits(.isHeader)
  }
}

/// Takes a card dropped on a column.
private struct ColumnDrop: ViewModifier {
  let isEnabled: Bool
  @Binding var isTargeted: Bool
  let onDrop: ([TaskDragItem]) -> Bool

  func body(content: Content) -> some View {
    if isEnabled {
      content.dropDestination(for: TaskDragItem.self) { items, _ in
        onDrop(items)
      } isTargeted: {
        isTargeted = $0
      }
    } else {
      content
    }
  }
}

/// Takes a card dropped on another card, and draws a line above it while one is over it: the
/// card lands there.
private struct CardDrop: ViewModifier {
  let isEnabled: Bool
  let onDrop: ([TaskDragItem]) -> Bool
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    if isEnabled {
      content
        .overlay(alignment: .top) {
          if isTargeted {
            Capsule()
              .fill(Spaces.Color.textPrimary)
              .frame(height: Spaces.Stroke.focus * 2)
              .offset(y: -Spaces.Space.xs - Spaces.Stroke.focus)
              .accessibilityHidden(true)
          }
        }
        .dropDestination(for: TaskDragItem.self) { items, _ in
          onDrop(items)
        } isTargeted: {
          isTargeted = $0
        }
        .animation(Spaces.Motion.quick, value: isTargeted)
    } else {
      content
    }
  }
}

/// One task as a card: a tick box, the text, and a line about it.
private struct BoardCard: View {
  let task: DailyTask
  let caption: String?
  let onOpen: () -> Void
  let onToggle: () -> Void

  @Environment(\.simulatedHover) private var simulatedHover
  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Spaces.Radius.control, style: .continuous)
    let hovered = isHovered || simulatedHover
    HStack(alignment: .top, spacing: Spaces.Space.s) {
      leading
      VStack(alignment: .leading, spacing: Spaces.Space.xxs) {
        Text(task.text)
          .spacesText(.body, color: task.isDone ? Spaces.Color.textSecondary : Spaces.Color.textPrimary)
          .strikethrough(task.isDone)
          .lineLimit(4)
          .fixedSize(horizontal: false, vertical: true)
        if let caption {
          Text(caption)
            .spacesText(.caption)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if task.notes != nil {
        Image(systemName: "note.text")
          .spacesText(.caption, color: Spaces.Color.textTertiary)
          .frame(height: Self.lineHeight)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, Spaces.Space.m)
    .padding(.vertical, Spaces.Space.s + Spaces.Space.xxs)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(hovered ? Spaces.Color.surfaceHover : Spaces.Color.raised, in: shape)
    .overlay {
      shape.strokeBorder(
        hovered ? Spaces.Color.borderStrong : Spaces.Color.border,
        lineWidth: Spaces.Stroke.hairline
      )
    }
    .contentShape(shape)
    .onTapGesture(perform: onOpen)
    .onHover { isHovered = $0 }
    .animation(Spaces.Motion.quick, value: isHovered)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(task.text)
    .accessibilityValue(accessibilityValue)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Opens the task to edit it")
    .accessibilityAction(.default, onOpen)
    .accessibilityActions {
      if task.status != .staged { Button(toggleName, action: onToggle) }
    }
  }

  /// The height of one line of body text, so a symbol beside the text sits on its first line.
  private static let lineHeight: CGFloat = 20

  @ViewBuilder private var leading: some View {
    if task.status == .staged {
      Image(systemName: "sparkles")
        .spacesText(.body, color: Spaces.Color.textTertiary)
        .frame(width: Spaces.Space.l + Spaces.Space.xxs, height: Self.lineHeight)
        .accessibilityHidden(true)
    } else {
      Button(action: onToggle) {
        Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
          .spacesText(.body, color: task.isDone ? Spaces.Color.accent : Spaces.Color.textTertiary)
          .frame(width: Spaces.Space.l + Spaces.Space.xxs, height: Self.lineHeight)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(task.isDone ? "Done: \(task.text)" : "Not done: \(task.text)")
    }
  }

  private var toggleName: String {
    switch task.status {
    case .staged: "Waits for your OK"
    case .open: "Mark as done"
    case .done: "Mark as not done"
    }
  }

  private var accessibilityValue: String {
    let status =
      switch task.status {
      case .staged: "Waiting for your OK"
      case .open: "Not done"
      case .done: "Done"
      }
    var parts = [status]
    if let caption { parts.append(caption.replacingOccurrences(of: TaskBoardCaption.separator, with: ", ")) }
    if task.notes != nil { parts.append("Has notes") }
    return parts.joined(separator: ", ")
  }
}

// MARK: - Snapshots

/// Snapshot cases for the board. See `SnapshotCase`.
enum TasksBoardSnapshots {
  @MainActor static var cases: [SnapshotCase] {
    let now = Date()
    let today = TaskDay.today(now)
    let meeting = Meeting(
      title: "Weekly product sync",
      startedAt: now.addingTimeInterval(-3 * 3_600),
      status: .ready
    )
    var sample = SampleData.tasks(now: now)
    if let index = sample.tasks.firstIndex(where: { $0.text.hasPrefix("Review the Gooseworks") }) {
      sample.tasks[index].notes = "Start with the sign-up screens."
      sample.tasks[index].meeting = meeting.id
    }
    let list = sample
    let canvas = SnapshotCase.Canvas.custom(width: 1_320, height: 640)
    func board(_ grouping: TaskBoardGrouping) -> some View {
      TasksBoard(
        list: list,
        meetings: [meeting],
        days: today...today.adding(days: 6),
        today: today,
        category: nil,
        grouping: grouping,
        onOpen: { _ in },
        onToggle: { _ in },
        onChange: { _, _ in }
      )
      .padding(Spaces.Space.xxl)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Spaces.Color.panel)
    }
    return TaskBoardGrouping.allCases.map { grouping in
      SnapshotCase(
        "tasks-board-\(grouping.rawValue)",
        canvas: canvas,
        model: { ScreenSamples.model(tasks: list) }
      ) {
        board(grouping)
      }
    }
  }
}
