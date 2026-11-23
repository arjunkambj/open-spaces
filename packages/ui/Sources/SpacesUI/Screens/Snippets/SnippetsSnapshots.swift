import SpacesDomain
import SwiftUI

/// Snapshot cases for this area. See `SnapshotCase`.
enum SnippetsSnapshots {
  @MainActor static var cases: [SnapshotCase] {
    let many = manySnippets()
    return [
      SnapshotCase("snippets") { SnippetsScreen(preview: SnippetsPreview(hoveredRow: 1)) },
      SnapshotCase("snippets-empty", model: { ScreenSamples.model() }) { SnippetsScreen() },
      SnapshotCase("snippets-long", model: { ScreenSamples.model(snippets: many) }) { SnippetsScreen() },
      SnapshotCase(
        "snippets-narrow",
        canvas: .custom(width: 640, height: 720),
        model: {
          ScreenSamples.model(snippets: many)
        }
      ) {
        SnippetsScreen().background(Spaces.Color.panel)
      },
      SnapshotCase("snippets-no-results", model: { ScreenSamples.model(snippets: many) }) {
        SnippetsScreen(preview: SnippetsPreview(query: "giraffe"))
      },
      SnapshotCase("snippets-add") {
        SnippetsScreen(
          preview: SnippetsPreview(
            editor: SnippetEditor(trigger: "my sign off", expansion: "Thanks,\nAlex")
          )
        )
      },
      SnapshotCase("snippets-add-error") {
        SnippetsScreen(
          preview: SnippetsPreview(editor: SnippetEditor(trigger: "sig", expansion: "", showsProblems: true))
        )
      },
      SnapshotCase("snippets-add-duplicate") {
        SnippetsScreen(
          preview: SnippetsPreview(
            editor: SnippetEditor(trigger: "My calendar-link", expansion: "https://cal.example.com/alex")
          )
        )
      },
      SnapshotCase("snippets-delete") {
        SnippetsScreen(
          preview: SnippetsPreview(
            deleting: Snippet(
              trigger: "intro email",
              expansion: "Hi! Great to meet you. I'd love to find 30 minutes to chat this week."
            )
          )
        )
      },
    ]
  }

  /// Enough snippets for the search field to show, with long and many-line ones.
  private static func manySnippets(now: Date = Date()) -> [Snippet] {
    let entries: [(String, String)] = [
      ("my calendar link", "https://cal.example.com/alex"),
      ("intro email", "Hi! Great to meet you. I'd love to find 30 minutes to chat this week."),
      ("my sign off", "Thanks,\nAlex"),
      ("my address", "42 Orchard Lane\nRivertown 10021"),
      (
        "standup update",
        "Yesterday I finished the upload retry and reviewed two pull requests. Today I am picking up the "
          + "billing migration and pairing with Jordan on the onboarding copy. Nothing is blocking me right "
          + "now, but I will need a review on the storage change before Thursday."
      ),
      ("my phone number", "+1 555 0100"),
      ("thanks for reaching out", "Thanks for reaching out. I will get back to you by the end of the week."),
      ("the really long phrase that I say to paste the project brief", "See the brief in the shared folder."),
      ("zoom room", "https://meet.example.com/alex-room"),
    ]
    return entries.enumerated().map { index, entry in
      Snippet(trigger: entry.0, expansion: entry.1, createdAt: now.addingTimeInterval(-Double(index) * 3_600))
    }
  }
}
