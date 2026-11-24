import SpacesDomain
import SpacesEngine
import SwiftUI

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
  private let now: Date?

  private static let dialogWidth: CGFloat = 520

  /// - openMeeting: shows a meeting, for an action item that came from one.
  public init(openMeeting: @escaping (Meeting.ID) -> Void = { _ in }) {
    self.init(preview: TasksPreview(), openMeeting: openMeeting)
  }

  /// Starts in a given state, so snapshots can show it.
  init(preview: TasksPreview, openMeeting: @escaping (Meeting.ID) -> Void = { _ in }) {
    self.openMeeting = openMeeting
    now = preview.now
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
      subtitle: "Your to-dos for each day. Tasks your AI tools suggest wait here for your OK."
    ) {
      Dropdown("Days to show", selection: $range, options: TaskRange.allCases, title: \.title)
      Button("Add task") { open(TaskEditor(day: firstDay, category: category ?? list.defaultCategory)) }
        .buttonStyle(.spaces(.primary))
    } content: {
      if range == .pick { datePickers }
      categoryTabs
      if !model.isLoaded {
        ScreenLoading("Loading your tasks…")
      } else {
        boardView
      }
    }
    .toast($toast)
    .dialog(
      isPresented: $isEditing,
      title: editor.original == nil ? "Add a task" : "Edit task",
      width: Self.dialogWidth
    ) {
      TaskEditorFields(editor: $editor, categories: list.categories, onSubmit: saveTask)
    } footer: {
      Button("Cancel") { isEditing = false }.buttonStyle(.spaces())
      Button(editor.original == nil ? "Add task" : "Save") { saveTask() }
        .buttonStyle(.spaces(.primary))
        .keyboardShortcut(.defaultAction)
        .disabled(editor.trimmedText.isEmpty)
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
  private var firstDay: TaskDay { days.contains(today) ? today : days.lowerBound }

  private var datePickers: some View {
    HStack(spacing: Spaces.Space.l) {
      DayPicker(label: "From", date: $pickedFrom)
      DayPicker(label: "To", date: $pickedTo)
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
            row(entry, day: board.earlier.first { $0.entry.id == entry.id }?.day)
          }
        }
      }
      ForEach(board.days) { section in
        PageSection(TasksLogic.title(section.day, today: today)) {
          CardList(section.entries) { entry in row(entry, day: nil) }
        } trailing: {
          Text(TasksLogic.count(section.entries)).spacesText(.caption)
        }
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
    var parts = ["Suggested by an AI tool", "for \(TasksLogic.inSentence(task.day, today: today))"]
    if category == nil { parts.append(task.category) }
    return parts.joined(separator: " · ")
  }

  /// - day: shown under the text, for things from another day than the section's.
  private func row(_ entry: TaskEntry, day: TaskDay?) -> some View {
    var details: [String] = []
    if let day { details.append(TasksLogic.title(day, today: today)) }
    switch entry {
    case .task(let task):
      if category == nil { details.append(task.category) }
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
      }
    )
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
    guard isEditing, !editor.trimmedText.isEmpty else { return }
    let editor = self.editor
    isEditing = false
    let day = TaskDay(editor.day)
    model.run { model in
      try await model.library.updateTaskList { list in
        if let original = editor.original {
          try list.edit(original.id, text: editor.text, day: day, category: editor.category)
        } else {
          try list.add(editor.text, day: day, category: editor.category)
        }
      }
    }
    toast = Toast(editor.original == nil ? "Added for \(TasksLogic.inSentence(day, today: today))" : "Saved")
  }

  private func toggle(_ entry: TaskEntry) {
    switch entry {
    case .task(let task):
      let done = !task.isDone
      model.run { try await $0.library.updateTaskList { try $0.setDone(task.id, done) } }
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

  private func delete(_ task: DailyTask) {
    model.run { try await $0.library.updateTaskList { try $0.remove(task.id) } }
    toast = Toast("Deleted “\(task.text)”")
  }

  private func approve(_ ids: Set<DailyTask.ID>) {
    model.run { try await $0.library.updateTaskList { $0.approve(ids) } }
    toast = Toast(ids.count == 1 ? "Added to your list" : "Added \(ids.count) tasks to your list")
  }

  private func reject(_ task: DailyTask) {
    model.run { try await $0.library.updateTaskList { try $0.remove(task.id) } }
    toast = Toast("Rejected “\(task.text)”", tone: .info)
  }

  private func saveCategory() {
    guard isNaming, !naming.trimmed.isEmpty, naming.problem(in: list) == nil else { return }
    let namer = naming
    isNaming = false
    model.run { model in
      try await model.library.updateTaskList { list in
        if let original = namer.original {
          try list.renameCategory(original, to: namer.name)
        } else {
          try list.addCategory(namer.name)
        }
      }
    }
    category = namer.trimmed
  }

  private func askToDelete(_ name: String) {
    deletingCategory = name
    isConfirmingCategoryDelete = true
  }

  private func confirmDeleteCategory() {
    isConfirmingCategoryDelete = false
    guard let name = deletingCategory else { return }
    category = nil
    model.run { try await $0.library.updateTaskList { try $0.removeCategory(name) } }
  }
}

/// One task or meeting action item: a tick box, the text, and actions on hover.
private struct TaskRow: View {
  let entry: TaskEntry
  let detail: String?
  let onToggle: () -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void

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
    .frame(minHeight: 52)
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

  var body: some View {
    VStack(alignment: .leading, spacing: Spaces.Space.s) {
      Text(label).spacesText(.captionStrong)
      DatePicker(label, selection: $date, displayedComponents: .date)
        .datePickerStyle(.compact)
        .labelsHidden()
        .accessibilityLabel(label)
    }
  }
}

/// What is being typed in the add or edit dialog.
struct TaskEditor: Equatable {
  var text = ""
  var day = Date()
  var category = ""
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
    original = task
  }

  var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The fields of the add or edit dialog.
private struct TaskEditorFields: View {
  @Binding var editor: TaskEditor
  let categories: [String]
  let onSubmit: () -> Void

  var body: some View {
    SpacesTextField(
      "Task",
      text: $editor.text,
      placeholder: "What do you want to get done?",
      focusOnAppear: true
    )
    .onSubmit(onSubmit)
    HStack(alignment: .top, spacing: Spaces.Space.l) {
      DayPicker(label: "Day", date: $editor.day)
      VStack(alignment: .leading, spacing: Spaces.Space.s) {
        Text("Category").spacesText(.captionStrong)
        Dropdown("Category", selection: $editor.category, options: options, title: { $0 })
      }
      Spacer(minLength: 0)
    }
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
    return nil
  }
}

/// A starting state for `TasksScreen`, so snapshots can show its parts.
struct TasksPreview {
  /// The moment the screen takes as now. `nil` for the real time.
  var now: Date?
  var range = TaskRange.today
  var category: String?
  var editor: TaskEditor?
  var naming: CategoryNamer?
  var deletingCategory: String?
}
