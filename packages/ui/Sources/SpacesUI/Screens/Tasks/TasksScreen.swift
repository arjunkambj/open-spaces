import SpacesDomain
import SpacesEngine
import SwiftUI
import UniformTypeIdentifiers

/// Daily tasks: a to-do list for each day, sorted into categories, with the open action items
/// from meetings beside them. Tasks an AI tool suggests wait at the top for the person's OK.
/// Reads `AppModel` from the environment.
public struct TasksScreen: View {
  @Environment(AppModel.self) private var model

  private let openMeeting: (Meeting.ID) -> Void
  @State private var range: TaskRange
  @State private var pickedFrom: Date
  @State private var pickedTo: Date
  @State private var category: String?
  @State private var editor: TaskEditor
  @State private var isEditing: Bool
  @State private var naming: CategoryNamer
  @State private var isNaming: Bool
  @State private var deletingCategory: String?
  @State private var isConfirmingCategoryDelete: Bool
  @State private var toast: Toast?
  @State private var layout: TaskLayout
  @State private var grouping: TaskBoardGrouping
  private let now: Date?
  /// Whether the view and grouping are saved for next time. Off for snapshots.
  private let remembersLayout: Bool

  private static let dialogWidth: CGFloat = 640

  /// - openMeeting: shows a meeting, for an action item that came from one.
  public init(openMeeting: @escaping (Meeting.ID) -> Void = { _ in }) {
    let defaults = UserDefaults.standard
    var preview = TasksPreview()
    preview.layout = defaults.string(forKey: LayoutKey.layout).flatMap(TaskLayout.init(rawValue:)) ?? .list
    preview.grouping =
      defaults.string(forKey: LayoutKey.grouping).flatMap(TaskBoardGrouping.init(rawValue:)) ?? .day
    self.init(preview: preview, openMeeting: openMeeting, remembersLayout: true)
  }

  private enum LayoutKey {
    static let layout = "tasks.layout"
    static let grouping = "tasks.boardGrouping"
  }

  /// Starts in a given state, so snapshots can show it.
  init(
    preview: TasksPreview,
    openMeeting: @escaping (Meeting.ID) -> Void = { _ in },
    remembersLayout: Bool = false
  ) {
    self.openMeeting = openMeeting
    self.remembersLayout = remembersLayout
    now = preview.now
    _layout = State(initialValue: preview.layout)
    _grouping = State(initialValue: preview.grouping)
    _range = State(initialValue: preview.range)
    _pickedFrom = State(initialValue: preview.now ?? Date())
    _pickedTo = State(initialValue: (preview.now ?? Date()).addingTimeInterval(6 * 86_400))
    _category = State(initialValue: preview.category)
    _editor = State(initialValue: preview.editor ?? TaskEditor())
    _isEditing = State(initialValue: preview.editor != nil)
    _naming = State(initialValue: preview.naming ?? CategoryNamer())
    _isNaming = State(initialValue: preview.naming != nil)
    _deletingCategory = State(initialValue: preview.deletingCategory)
    _isConfirmingCategoryDelete = State(initialValue: preview.deletingCategory != nil)
  }

  public var body: some View {
    Page(
      title: "Tasks",
      subtitle: "Your to-dos for each day. Tasks your AI tools suggest wait here for your OK.",
      width: layout == .board ? .wide : .regular
    ) {
      if layout != .inbox {
        Dropdown("Days to show", selection: $range, options: TaskRange.allCases, title: \.title)
      }
      Button("Add task") { open(TaskEditor(day: firstDay, category: category ?? list.defaultCategory)) }
        .buttonStyle(.spaces(.primary))
    } content: {
      HStack(spacing: Spaces.Space.m) {
        Tabs(selection: $layout, options: TaskLayout.allCases, style: .segmented, title: \.title)
          .fixedSize()
          .accessibilityLabel("View")
        if layout == .board {
          Dropdown("Group by", selection: $grouping, options: TaskBoardGrouping.allCases) {
            "By \($0.title.lowercased())"
          }
        }
        Spacer(minLength: 0)
      }
      if range == .pick && layout != .inbox { datePickers }
      categoryTabs
      if !model.isLoaded {
        ScreenLoading("Loading your tasks…")
      } else {
        switch layout {
        case .inbox: inbox
        case .list: boardView
        case .board: kanban
        }
      }
    }
    .toast($toast)
    .onChange(of: layout) { _, layout in
      if remembersLayout { UserDefaults.standard.set(layout.rawValue, forKey: LayoutKey.layout) }
    }
    .onChange(of: grouping) { _, grouping in
      if remembersLayout { UserDefaults.standard.set(grouping.rawValue, forKey: LayoutKey.grouping) }
    }
    .dialog(
      isPresented: $isEditing,
      title: editor.original == nil ? "Add a task" : "Edit task",
      width: Self.dialogWidth
    ) {
      TaskEditorFields(
        editor: $editor,
        categories: list.categories,
        meetings: model.meetingList,
        today: today,
        onSubmit: saveTask
      )
    } footer: {
      Button("Cancel") { isEditing = false }.buttonStyle(.spaces())
      Button(editor.original == nil ? "Add task" : "Save") { saveTask() }
        .buttonStyle(.spaces(.primary))
        .keyboardShortcut(.defaultAction)
        .disabled(editor.trimmedText.isEmpty || editor.problem != nil)
    }
    .dialog(
      isPresented: $isNaming,
      title: naming.original == nil ? "New category" : "Rename “\(naming.original ?? "")”",
      subtitle: naming.original == nil ? "Sort your tasks into groups, such as a project or a client." : nil
    ) {
      SpacesTextField(
        "Name",
        text: $naming.name,
        placeholder: "For example, Home",
        error: naming.problem(in: list),
        focusOnAppear: true
      )
      .onSubmit(saveCategory)
    } footer: {
      Button("Cancel") { isNaming = false }.buttonStyle(.spaces())
      Button(naming.original == nil ? "Add category" : "Rename") { saveCategory() }
        .buttonStyle(.spaces(.primary))
        .keyboardShortcut(.defaultAction)
        .disabled(naming.trimmed.isEmpty || naming.problem(in: list) != nil)
    }
    .dialog(
      isPresented: $isConfirmingCategoryDelete,
      title: "Delete “\(deletingCategory ?? "")”?",
      subtitle: deleteCategoryHint
    ) {
      EmptyView()
    } footer: {
      // Return must never delete: it presses Cancel.
      Button("Cancel") { isConfirmingCategoryDelete = false }
        .buttonStyle(.spaces())
        .keyboardShortcut(.defaultAction)
      Button("Delete") { confirmDeleteCategory() }.buttonStyle(.spaces(.destructive))
    }
  }

  // MARK: - Parts

  private var list: TaskList { model.taskList }
  private var today: TaskDay { TaskDay.today(now ?? Date()) }
  private var days: ClosedRange<TaskDay> {
    range.days(today: today, picked: (TaskDay(pickedFrom), TaskDay(pickedTo)))
  }
  /// The day a new task starts on: today when it is shown, otherwise the first day shown.
  private var firstDay: TaskDay { layout == .inbox || days.contains(today) ? today : days.lowerBound }

  /// The Inbox view: what needs the person now, whatever days the other views show. Tasks waiting
  /// for an OK, then what is overdue, then what is still open today.
  @ViewBuilder private var inbox: some View {
    let board = TasksLogic.board(
      list: list,
      meetings: model.meetingList,
      days: today...today,
      today: today,
      category: category
    )
    let openToday = (board.days.first?.entries ?? []).filter { !$0.isDone }
    let tasks = openToday.compactMap { entry -> DailyTask.ID? in
      if case .task(let task) = entry { return task.id }
      return nil
    }
    if board.waiting.isEmpty && board.earlier.isEmpty && openToday.isEmpty {
      EmptyState(
        "You're all caught up",
        message: "Nothing is waiting for your OK, overdue or still open today."
      ) {
        SymbolTile("tray")
      } action: {
        Button("Add task") { open(TaskEditor(day: today, category: category ?? list.defaultCategory)) }
          .buttonStyle(.spaces(.tertiary))
      }
      .frame(maxHeight: .infinity)
    } else {
      if !board.waiting.isEmpty { waitingSection(board.waiting) }
      if !board.earlier.isEmpty {
        PageSection("Overdue") {
          CardList(board.earlier.map(\.entry)) { entry in
            let day = board.earlier.first { $0.entry.id == entry.id }?.day ?? today
            row(entry, on: day, among: [], showsDay: true, takesDrops: false)
          }
        } trailing: {
          if board.earlier.count > 1 {
            let ids = board.earlier.compactMap { item -> DailyTask? in
              if case .task(let task) = item.entry { return task }
              return nil
            }
            if !ids.isEmpty {
              Button("Move all to today") { moveToToday(ids) }
                .buttonStyle(.spaces(.tertiary, size: .small))
            }
          }
        }
      }
      PageSection("Today") {
        if openToday.isEmpty {
          Text("Nothing left for today. Drag an overdue task here to do it today.")
            .spacesText(.caption, color: Spaces.Color.textTertiary)
            .frame(maxWidth: .infinity, minHeight: ListRowMetrics.minHeight, alignment: .leading)
        } else {
          CardList(openToday) { entry in
            row(entry, on: today, among: tasks, showsDay: false, takesDrops: true)
          }
        }
      } trailing: {
        if !openToday.isEmpty { Text(TasksLogic.count(openToday)).spacesText(.caption) }
      }
      .modifier(TaskDrop(highlight: .area) { drop($0, on: today, before: nil) })
    }
  }

  /// Moves overdue tasks to the end of today.
  private func moveToToday(_ tasks: [DailyTask]) {
    let today = self.today
    let ids = tasks.map(\.id)
    change("Moved \(ids.count) tasks to today") { list in
      for id in ids { try list.move(id, to: today, before: nil) }
    }
  }

  private var datePickers: some View {
    HStack(spacing: Spaces.Space.l) {
      DayPicker(label: "From", date: $pickedFrom, today: today)
      DayPicker(label: "To", date: $pickedTo, today: today)
      Spacer(minLength: 0)
    }
  }

  private var categoryTabs: some View {
    let options: [String?] = [nil] + list.categories.map(Optional.some)
    return Tabs(selection: $category, options: options, title: { $0 ?? "All" }) {
      if let category, list.category(named: category) != nil {
        OverflowMenu(label: "Category options") {
          Button("Rename “\(category)”…") { openNamer(CategoryNamer(renaming: category)) }
          Button("Delete “\(category)”…", role: .destructive) { askToDelete(category) }
            .disabled(list.categories.count < 2)
        }
      }
      IconButton("plus", label: "New category", size: .small) { openNamer(CategoryNamer()) }
    }
    .onChange(of: list.categories) { _, categories in
      // A category deleted or renamed elsewhere (by an agent, say) is no longer a tab.
      if let category, !categories.contains(category) { self.category = nil }
    }
  }

  /// The Board view. Tasks waiting for an OK have a column of their own when grouped by status;
  /// otherwise they keep their section above the board.
  @ViewBuilder private var kanban: some View {
    let waiting = list.staged.filter { category == nil || $0.category == category }
    if grouping != .status && !waiting.isEmpty { waitingSection(waiting) }
    TasksBoard(
      list: list,
      meetings: model.meetingList,
      days: days,
      today: today,
      category: category,
      grouping: grouping,
      onOpen: { open(TaskEditor($0)) },
      onToggle: { toggle(.task($0)) },
      onChange: { message, work in change(message, work) }
    )
  }

  @ViewBuilder private var boardView: some View {
    let board = TasksLogic.board(
      list: list,
      meetings: model.meetingList,
      days: days,
      today: today,
      category: category
    )
    if board.isEmpty {
      empty
    } else {
      if !board.waiting.isEmpty { waitingSection(board.waiting) }
      if !board.earlier.isEmpty {
        PageSection("Not done from earlier") {
          CardList(board.earlier.map(\.entry)) { entry in
            let day = board.earlier.first { $0.entry.id == entry.id }?.day ?? today
            row(entry, on: day, among: [], showsDay: true, takesDrops: false)
          }
        }
      }
      ForEach(board.days) { section in
        let tasks = section.entries.compactMap { entry -> DailyTask.ID? in
          if case .task(let task) = entry, !task.isDone { return task.id }
          return nil
        }
        PageSection(TasksLogic.title(section.day, today: today)) {
          if section.entries.isEmpty {
            Text("Nothing planned. Drag a task here to move it to this day.")
              .spacesText(.caption, color: Spaces.Color.textTertiary)
              .frame(maxWidth: .infinity, minHeight: ListRowMetrics.minHeight, alignment: .leading)
          } else {
            CardList(section.entries) { entry in
              row(entry, on: section.day, among: tasks, showsDay: false, takesDrops: true)
            }
          }
        } trailing: {
          if !section.entries.isEmpty {
            Text(TasksLogic.count(section.entries)).spacesText(.caption)
          }
        }
        .modifier(TaskDrop(highlight: .area) { drop($0, on: section.day, before: nil) })
      }
    }
  }

  private func waitingSection(_ tasks: [DailyTask]) -> some View {
    PageSection("Waiting for your OK") {
      CardList(tasks, style: .outlined) { task in
        ListRow(task.text, subtitle: waitingDetail(task)) {
          Image(systemName: "sparkles")
            .spacesText(.cardTitle, color: Spaces.Color.textTertiary)
            .frame(minWidth: Spaces.Space.xl)
            .accessibilityHidden(true)
        } trailing: {
          Button("Reject") { reject(task) }
            .buttonStyle(.spaces(.tertiary, size: .small))
            .accessibilityLabel("Reject: \(task.text)")
          Button("Add to list") { approve([task.id]) }
            .buttonStyle(.spaces(.secondary, size: .small))
            .accessibilityLabel("Add to your list: \(task.text)")
        }
        .onTap { open(TaskEditor(task)) }
        .lineLimit(2)
      }
    } trailing: {
      if tasks.count > 1 {
        Button("Add all \(tasks.count)") { approve(Set(tasks.map(\.id))) }
          .buttonStyle(.spaces(.tertiary, size: .small))
      }
    }
  }

  private func waitingDetail(_ task: DailyTask) -> String {
    let tool = task.agent.map { AgentStatus.name(of: AgentClient(name: $0)) } ?? "an AI tool"
    var parts = ["Suggested by \(tool)", "for \(TasksLogic.inSentence(task.day, today: today))"]
    if category == nil { parts.append(task.category) }
    if let repeats = task.repeats { parts.append(TasksLogic.repeatTitle(repeats)) }
    return parts.joined(separator: " · ")
  }

  /// - day: the day the row is on. A task dropped on the row lands on it, just above the row.
  /// - among: the open tasks of that day in their order, for moving a task up or down.
  /// - showsDay: writes the day under the text, for a row outside its day's section.
  /// - takesDrops: whether a task can be dropped on the row.
  @ViewBuilder
  private func row(
    _ entry: TaskEntry,
    on day: TaskDay,
    among tasks: [DailyTask.ID],
    showsDay: Bool,
    takesDrops: Bool
  ) -> some View {
    let base = rowView(entry, showsDay ? day : nil)
    // Done tasks and meeting action items are shown after the open tasks, so a task dropped on
    // one of them goes after the open tasks, at the end of the day.
    let before: DailyTask.ID? = if case .task(let task) = entry, !task.isDone { task.id } else { nil }
    let drop = TaskDrop(highlight: .line, isEnabled: takesDrops) { self.drop($0, on: day, before: before) }
    switch entry {
    case .task(let task):
      base
        .modifier(TaskDrag(task: task))
        .modifier(drop)
        .accessibilityActions { moveActions(task, among: tasks) }
    case .action:
      base.modifier(drop)
    }
  }

  /// What VoiceOver offers in place of a drag.
  @ViewBuilder private func moveActions(_ task: DailyTask, among tasks: [DailyTask.ID]) -> some View {
    if let index = tasks.firstIndex(of: task.id) {
      if index > 0 {
        Button("Move up") { move(task, to: task.day, before: tasks[index - 1]) }
      }
      if index < tasks.count - 1 {
        Button("Move down") {
          move(task, to: task.day, before: index + 2 < tasks.count ? tasks[index + 2] : nil)
        }
      }
    }
    Button("Move to the next day") { move(task, to: task.day.adding(days: 1), before: nil) }
    Button("Move to the day before") { move(task, to: task.day.adding(days: -1), before: nil) }
  }

  private func rowView(_ entry: TaskEntry, _ day: TaskDay?) -> some View {
    var details: [String] = []
    if let day { details.append(TasksLogic.title(day, today: today)) }
    switch entry {
    case .task(let task):
      if category == nil { details.append(task.category) }
      if let repeats = task.repeats { details.append(TasksLogic.repeatTitle(repeats)) }
      if let title = meetingTitle(task.meeting) { details.append("Meeting “\(title)”") }
      if task.notes != nil { details.append("Has notes") }
    case .action(let item, _, let title):
      details.append("From the meeting “\(title)”")
      if let owner = item.owner, !owner.isEmpty { details.append(owner) }
    }
    return TaskRow(
      entry: entry,
      detail: details.isEmpty ? nil : details.joined(separator: " · "),
      onToggle: { toggle(entry) },
      onEdit: {
        switch entry {
        case .task(let task): open(TaskEditor(task))
        case .action(_, let meeting, _): openMeeting(meeting)
        }
      },
      onDelete: {
        if case .task(let task) = entry { delete(task) }
      },
      onOpenMeeting: linkedMeeting(entry).map { id in { openMeeting(id) } }
    )
  }

  /// The title of a meeting a task links to, when that meeting is still there.
  private func meetingTitle(_ id: Meeting.ID?) -> String? {
    guard let id else { return nil }
    return model.meetingList.first { $0.id == id }?.title
  }

  /// The meeting a task links to, when it is still there.
  private func linkedMeeting(_ entry: TaskEntry) -> Meeting.ID? {
    guard case .task(let task) = entry, let id = task.meeting, meetingTitle(id) != nil else { return nil }
    return id
  }

  private var empty: some View {
    EmptyState(
      emptyTitle,
      message:
        "Add what you want to get done, or ask your AI tool to plan your day. "
        + "What it suggests shows up here for your OK."
    ) {
      SymbolTile("checklist")
    } action: {
      Button("Add task") { open(TaskEditor(day: firstDay, category: category ?? list.defaultCategory)) }
        .buttonStyle(.spaces(.tertiary))
    }
    .frame(maxHeight: .infinity)
  }

  private var emptyTitle: String {
    let where_ = category.map { " in \($0)" } ?? ""
    switch range {
    case .today: return "Nothing to do today\(where_)"
    case .tomorrow: return "Nothing planned for tomorrow\(where_)"
    default: return "No tasks on these days\(where_)"
    }
  }

  private var deleteCategoryHint: String {
    guard let name = deletingCategory else { return "" }
    let count = list.tasks.filter { $0.category == name }.count
    let home = list.categories.first { $0 != name } ?? ""
    return count == 0
      ? "It has no tasks."
      : "Its \(count == 1 ? "task moves" : "\(count) tasks move") to \(home)."
  }

  // MARK: - Actions

  private func open(_ editor: TaskEditor) {
    self.editor = editor
    isEditing = true
  }

  private func openNamer(_ namer: CategoryNamer) {
    naming = namer
    isNaming = true
  }

  private func saveTask() {
    // Return in a field can reach this twice: from the field and from the default button.
    guard isEditing, !editor.trimmedText.isEmpty, editor.problem == nil else { return }
    let editor = self.editor
    isEditing = false
    let day = TaskDay(editor.day)
    let saved = editor.original == nil ? "Added for \(TasksLogic.inSentence(day, today: today))" : "Saved"
    change(saved) { list in
      if let original = editor.original {
        try list.edit(
          original.id,
          text: editor.text,
          day: day,
          category: editor.category,
          repeats: .some(editor.repeats),
          notes: .some(editor.notes),
          meeting: .some(editor.meeting)
        )
      } else {
        try list.add(
          editor.text,
          day: day,
          category: editor.category,
          repeats: editor.repeats,
          notes: editor.notes,
          meeting: editor.meeting
        )
      }
    }
  }

  /// Changes the stored task list, and shows `message` once the change is saved. A change that
  /// fails shows its error instead.
  private func change(
    _ message: String? = nil,
    tone: NoticeTone = .success,
    then done: @escaping @MainActor () -> Void = {},
    _ work: @escaping @Sendable (inout TaskList) throws -> Void
  ) {
    Task {
      let saved = await model.attempt { try await $0.library.updateTaskList(work) }
      guard saved else { return }
      if let message { toast = Toast(message, tone: tone) }
      done()
    }
  }

  private func toggle(_ entry: TaskEntry) {
    switch entry {
    case .task(let task):
      let done = !task.isDone
      let today = self.today
      var message: String?
      if done, let repeats = task.repeats, task.repeatedAs == nil {
        let next = repeats.next(after: task.day, notBefore: today)
        message = "Done. The next one is on \(TasksLogic.inSentence(next, today: today))."
      }
      change(message) { try $0.setDone(task.id, done, today: today) }
    case .action(let item, let meeting, _):
      model.run { model in
        try await model.library.updateMeeting(meeting) { meeting in
          guard var notes = meeting.notes,
            let index = notes.actionItems.firstIndex(where: { $0.id == item.id })
          else { return }
          notes.actionItems[index].done.toggle()
          meeting.notes = notes
        }
      }
    }
  }

  /// Handles a task dropped on a day: moves it there, just above `before` when that is given.
  /// Returns false for anything that is not one of the tasks.
  private func drop(_ items: [TaskDragItem], on day: TaskDay, before: DailyTask.ID?) -> Bool {
    guard let id = items.first?.id, let task = list.task(id), id != before else { return false }
    // Done tasks are shown after the open ones, so a done task always goes to the end of the day.
    move(task, to: day, before: task.isDone ? nil : before)
    return true
  }

  private func move(_ task: DailyTask, to day: TaskDay, before: DailyTask.ID?) {
    let message = task.day == day ? nil : "Moved to \(TasksLogic.inSentence(day, today: today))"
    change(message) { try $0.move(task.id, to: day, before: before) }
  }

  private func delete(_ task: DailyTask) {
    change("Deleted “\(task.text)”") { try $0.remove(task.id) }
  }

  private func approve(_ ids: Set<DailyTask.ID>) {
    change(ids.count == 1 ? "Added to your list" : "Added \(ids.count) tasks to your list") {
      $0.approve(ids)
    }
  }

  private func reject(_ task: DailyTask) {
    change("Rejected “\(task.text)”", tone: .info) { try $0.remove(task.id) }
  }

  private func saveCategory() {
    guard isNaming, !naming.trimmed.isEmpty, naming.problem(in: list) == nil else { return }
    let namer = naming
    isNaming = false
    // The tab moves to the category once it is saved, so a failed save leaves the tabs as they were.
    change(then: { category = namer.trimmed }) { list in
      if let original = namer.original {
        try list.renameCategory(original, to: namer.name)
      } else {
        try list.addCategory(namer.name)
      }
    }
  }

  private func askToDelete(_ name: String) {
    deletingCategory = name
    isConfirmingCategoryDelete = true
  }

  private func confirmDeleteCategory() {
    isConfirmingCategoryDelete = false
    guard let name = deletingCategory else { return }
    category = nil
    change { try $0.removeCategory(name) }
  }
}

/// One task or meeting action item: a tick box, the text, and actions on hover.
private struct TaskRow: View {
  let entry: TaskEntry
  let detail: String?
  let onToggle: () -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void
  /// Opens the meeting a task links to. `nil` when it links to none.
  var onOpenMeeting: (() -> Void)?

  @Environment(\.simulatedHover) private var simulatedHover
  @State private var isHovered = false
  /// Whether the keyboard is on one of the row's controls.
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(alignment: .center, spacing: Spaces.Space.m) {
      Button(action: onToggle) {
        Image(systemName: entry.isDone ? "checkmark.circle.fill" : "circle")
          .spacesText(.cardTitle, color: entry.isDone ? Spaces.Color.accent : Spaces.Color.textTertiary)
          .frame(minWidth: Spaces.Space.xl, minHeight: Spaces.Space.xl)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(entry.isDone ? "Done: \(entry.text)" : "Not done: \(entry.text)")
      .accessibilityHint(entry.isDone ? "Marks it as not done" : "Marks it as done")
      VStack(alignment: .leading, spacing: Spaces.Space.xxs) {
        Text(entry.text)
          .spacesText(.body, color: entry.isDone ? Spaces.Color.textSecondary : Spaces.Color.textPrimary)
          .strikethrough(entry.isDone)
          .lineLimit(3)
        if let detail {
          Text(detail).spacesText(.caption).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: Spaces.Space.xxs) {
        switch entry {
        case .task(let task):
          if let onOpenMeeting {
            IconButton("arrow.up.right", label: "Open the meeting", size: .small, action: onOpenMeeting)
          }
          IconButton("pencil", label: "Edit \(task.text)", size: .small, action: onEdit)
          IconButton("trash", label: "Delete \(task.text)", size: .small, action: onDelete)
        case .action:
          IconButton("arrow.up.right", label: "Open the meeting", size: .small, action: onEdit)
        }
      }
      // Tab reaches the buttons even while they are unseen, so they show for the keyboard too.
      .opacity(isHovered || simulatedHover || isFocused ? 1 : 0)
    }
    .focused($isFocused)
    .padding(.vertical, Spaces.Space.s)
    .frame(minHeight: ListRowMetrics.minHeight)
    .rowChrome(isHighlighted: false)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(Spaces.Motion.quick, value: isHovered)
  }
}

/// A labelled date field that opens a calendar.
private struct DayPicker: View {
  let label: String
  @Binding var date: Date
  /// The day the quick choices count from.
  let today: TaskDay
  @State private var isOpen = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spaces.Space.s) {
      Text(label).spacesText(.captionStrong)
      Button {
        isOpen = true
      } label: {
        HStack(spacing: Spaces.Space.m) {
          Image(systemName: "calendar")
            .foregroundStyle(Spaces.Color.textSecondary)
            .accessibilityHidden(true)
          Text(TasksLogic.title(TaskDay(date), today: today)).spacesText(.body).lineLimit(1)
          Spacer(minLength: 0)
          Image(systemName: "chevron.down")
            .spacesText(.caption, color: Spaces.Color.textSecondary)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, Spaces.Space.m)
        .frame(minWidth: DayPickerMetrics.width, minHeight: DayPickerMetrics.height)
        .background(Spaces.Color.raised, in: RoundedRectangle(cornerRadius: Spaces.Radius.control))
        .overlay {
          RoundedRectangle(cornerRadius: Spaces.Radius.control)
            .strokeBorder(Spaces.Color.borderStrong, lineWidth: Spaces.Stroke.hairline)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .fixedSize()
      .accessibilityLabel(label)
      .accessibilityValue(TasksLogic.title(TaskDay(date), today: today))
      .popover(isPresented: $isOpen, arrowEdge: .bottom) { calendar }
    }
  }

  private var calendar: some View {
    VStack(alignment: .leading, spacing: Spaces.Space.m) {
      HStack(spacing: Spaces.Space.s) {
        quick("Today", today)
        quick("Tomorrow", today.adding(days: 1))
        quick("Next week", today.adding(days: 7))
      }
      DatePicker(label, selection: $date, displayedComponents: .date)
        .datePickerStyle(.graphical)
        .labelsHidden()
    }
    .padding(Spaces.Space.l)
  }

  private func quick(_ title: String, _ day: TaskDay) -> some View {
    Button(title) {
      date = day.start().addingTimeInterval(12 * 3_600)
      isOpen = false
    }
    .buttonStyle(.spaces(.tertiary, size: .small))
  }
}

private enum DayPickerMetrics {
  static let width: CGFloat = 200
  static let height: CGFloat = 36
}

/// What is being typed in the add or edit dialog.
struct TaskEditor: Equatable {
  var text = ""
  var day = Date()
  var category = ""
  var repeats: TaskRepeat?
  var notes = ""
  var meeting: Meeting.ID?
  /// The task being edited, or `nil` when adding.
  var original: DailyTask?

  init() {}

  init(text: String = "", day: TaskDay, category: String) {
    self.text = text
    self.day = day.start().addingTimeInterval(12 * 3_600)
    self.category = category
  }

  init(_ task: DailyTask) {
    text = task.text
    day = task.day.start().addingTimeInterval(12 * 3_600)
    category = task.category
    repeats = task.repeats
    notes = task.notes ?? ""
    meeting = task.meeting
    original = task
  }

  var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Why the text cannot be saved, or `nil` when it can. Empty text only disables the button.
  var problem: String? { textProblem ?? notesProblem }

  var textProblem: String? {
    trimmedText.count > TaskList.textLimit ? "A task can be at most \(TaskList.textLimit) characters." : nil
  }

  /// Counted as the notes are stored: without white space at either end.
  var notesProblem: String? {
    let stored = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    return stored.count > TaskList.notesLimit
      ? "Notes can be at most \(TaskList.notesLimit) characters." : nil
  }
}

/// The fields of the add or edit dialog.
private struct TaskEditorFields: View {
  @Binding var editor: TaskEditor
  let categories: [String]
  let meetings: [Meeting]
  let today: TaskDay
  let onSubmit: () -> Void

  /// The newest meetings offered in the meeting list.
  private static let meetingChoices = 30
  private static let notesHeight: CGFloat = 96

  var body: some View {
    SpacesTextField(
      "Task",
      text: $editor.text,
      placeholder: "What do you want to get done?",
      error: editor.textProblem,
      focusOnAppear: true
    )
    .onSubmit(onSubmit)
    HStack(alignment: .top, spacing: Spaces.Space.l) {
      DayPicker(label: "Day", date: $editor.day, today: today)
      VStack(alignment: .leading, spacing: Spaces.Space.s) {
        Text("Category").spacesText(.captionStrong)
        Dropdown("Category", selection: $editor.category, options: options, title: { $0 })
      }
      VStack(alignment: .leading, spacing: Spaces.Space.s) {
        Text("Repeat").spacesText(.captionStrong)
        Dropdown(
          "Repeat",
          selection: $editor.repeats,
          options: [nil] + TaskRepeat.allCases.map(Optional.some),
          title: { $0.map(TasksLogic.repeatTitle) ?? "Never" }
        )
      }
      Spacer(minLength: 0)
    }
    VStack(alignment: .leading, spacing: Spaces.Space.s) {
      Text("Meeting").spacesText(.captionStrong)
      Dropdown("Meeting", selection: $editor.meeting, options: meetingOptions, title: meetingTitle)
    }
    SpacesTextEditor(
      "Notes",
      text: $editor.notes,
      placeholder: "Anything that helps: links, details, who to ask",
      error: editor.notesProblem,
      height: Self.notesHeight
    )
  }

  /// No meeting, the newest meetings, and the task's own meeting when it is older than those.
  private var meetingOptions: [Meeting.ID?] {
    var ids = meetings.prefix(Self.meetingChoices).map(\.id)
    if let linked = editor.meeting, !ids.contains(linked) { ids.append(linked) }
    return [nil] + ids.map(Optional.some)
  }

  private func meetingTitle(_ id: Meeting.ID?) -> String {
    guard let id else { return "None" }
    guard let meeting = meetings.first(where: { $0.id == id }) else { return "A deleted meeting" }
    return "\(meeting.title) · \(TasksLogic.title(TaskDay(meeting.startedAt), today: today))"
  }

  /// The categories, and the task's own one when it is not among them (a hand-edited file).
  private var options: [String] {
    categories.contains(editor.category) || editor.category.isEmpty
      ? categories : categories + [editor.category]
  }
}

/// The name typed into the new or rename category dialog.
struct CategoryNamer: Equatable {
  var name = ""
  /// The category being renamed, or `nil` for a new one.
  var original: String?

  init(name: String = "") { self.name = name }

  init(renaming category: String) {
    name = category
    original = category
  }

  var trimmed: String { name.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

  /// Why the name cannot be used, or `nil` when it can. An empty name only disables the button.
  func problem(in list: TaskList) -> String? {
    if trimmed.count > TaskList.categoryLimit {
      return "A category name can be at most \(TaskList.categoryLimit) characters."
    }
    if let taken = list.category(named: trimmed), taken != original {
      return "There is already a category called “\(taken)”."
    }
    if original == nil, list.categories.count >= TaskList.mostCategories {
      return "You can have up to \(TaskList.mostCategories) categories. Delete one first."
    }
    return nil
  }
}

/// The two ways the Tasks tab shows tasks.
enum TaskLayout: String, CaseIterable, Identifiable, Hashable {
  /// What needs the person now: waiting, overdue and open today, whatever the days chosen.
  case inbox
  /// Sections per day, one task a row.
  case list
  /// Columns of cards, by day, category or status.
  case board

  var id: String { rawValue }

  var title: String {
    switch self {
    case .inbox: "Inbox"
    case .list: "List"
    case .board: "Kanban"
    }
  }
}

/// A starting state for `TasksScreen`, so snapshots can show its parts.
struct TasksPreview {
  /// The moment the screen takes as now. `nil` for the real time.
  var now: Date?
  var layout = TaskLayout.list
  var grouping = TaskBoardGrouping.day
  var range = TaskRange.today
  var category: String?
  var editor: TaskEditor?
  var naming: CategoryNamer?
  var deletingCategory: String?
}

/// What travels when a task is dragged: its ID, as a type of its own, so only the Tasks tab
/// takes it and it is never pasted into a text field. The app declares the type in its Info.plist.
struct TaskDragItem: Codable, Transferable {
  let id: DailyTask.ID

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: UTType(exportedAs: "dev.openspaces.task"))
  }
}

/// Lets a task be dragged onto a day or another task.
private struct TaskDrag: ViewModifier {
  let task: DailyTask

  func body(content: Content) -> some View {
    content.draggable(TaskDragItem(id: task.id)) {
      Text(task.text)
        .spacesText(.body)
        .lineLimit(1)
        .padding(.horizontal, Spaces.Space.m)
        .padding(.vertical, Spaces.Space.s)
        .background(Spaces.Color.raised, in: RoundedRectangle(cornerRadius: Spaces.Radius.control))
    }
  }
}

/// Takes a dragged task. `onDrop` gets what was dropped and says whether it was a task.
private struct TaskDrop: ViewModifier {
  enum Highlight {
    /// A line above the view: the task lands there.
    case line
    /// A soft fill behind the whole view: the task lands at the end.
    case area
  }

  let highlight: Highlight
  var isEnabled = true
  let onDrop: ([TaskDragItem]) -> Bool
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    if isEnabled { target(content) } else { content }
  }

  private func target(_ content: Content) -> some View {
    content
      .background {
        if isTargeted && highlight == .area {
          RoundedRectangle(cornerRadius: Spaces.Radius.control, style: .continuous)
            .fill(Spaces.Color.surfaceHover)
            .padding(-Spaces.Space.s)
        }
      }
      .overlay(alignment: .top) {
        if isTargeted && highlight == .line {
          Rectangle()
            .fill(Spaces.Color.textPrimary)
            .frame(height: Spaces.Stroke.focus)
            .accessibilityHidden(true)
        }
      }
      .dropDestination(for: TaskDragItem.self) { items, _ in
        onDrop(items)
      } isTargeted: {
        isTargeted = $0
      }
      .animation(Spaces.Motion.quick, value: isTargeted)
  }
}
