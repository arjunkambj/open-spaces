import SpacesDomain
import SwiftUI

/// Snapshot cases for this area. See `SnapshotCase`.
enum TasksSnapshots {
  @MainActor static var cases: [SnapshotCase] {
    let now = Date()
    let sample = SampleData.tasks(now: now)
    let gooseworks = sample.tasks.first { $0.category == "Gooseworks" && $0.status == .open }
    return [
      SnapshotCase("tasks", model: { ScreenSamples.model(tasks: sample) }) {
        TasksScreen(preview: TasksPreview(now: now))
      },
      SnapshotCase("tasks-week", model: { ScreenSamples.model(tasks: sample) }) {
        TasksScreen(preview: TasksPreview(now: now, range: .nextWeek))
      },
      SnapshotCase("tasks-category", model: { ScreenSamples.model(tasks: sample) }) {
        TasksScreen(preview: TasksPreview(now: now, category: "Gooseworks"))
      },
      SnapshotCase("tasks-pick-dates", model: { ScreenSamples.model(tasks: sample) }) {
        TasksScreen(preview: TasksPreview(now: now, range: .pick))
      },
      SnapshotCase("tasks-empty", model: { ScreenSamples.model() }) {
        TasksScreen(preview: TasksPreview(now: now))
      },
      SnapshotCase("tasks-add", model: { ScreenSamples.model(tasks: sample) }) {
        TasksScreen(
          preview: TasksPreview(
            now: now,
            editor: TaskEditor(text: "Call the bank", day: TaskDay.today(now), category: "General")
          )
        )
      },
      SnapshotCase("tasks-edit", model: { ScreenSamples.model(tasks: sample) }) {
        TasksScreen(preview: TasksPreview(now: now, editor: gooseworks.map(TaskEditor.init)))
      },
      SnapshotCase("tasks-new-category", model: { ScreenSamples.model(tasks: sample) }) {
        TasksScreen(preview: TasksPreview(now: now, naming: CategoryNamer(name: "gooseworks")))
      },
      SnapshotCase("tasks-delete-category", model: { ScreenSamples.model(tasks: sample) }) {
        TasksScreen(preview: TasksPreview(now: now, category: "Gooseworks", deletingCategory: "Gooseworks"))
      },
    ]
  }
}
