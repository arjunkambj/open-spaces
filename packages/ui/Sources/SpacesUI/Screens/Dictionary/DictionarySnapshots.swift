import SpacesDomain
import SwiftUI

/// Snapshot cases for this area. See `SnapshotCase`.
enum DictionarySnapshots {
  @MainActor static var cases: [SnapshotCase] {
    let many = manyWords()
    return [
      SnapshotCase("dictionary") { DictionaryScreen(preview: DictionaryPreview(hoveredRow: 0)) },
      SnapshotCase("dictionary-phone", canvas: .phone) { DictionaryScreen() },
      SnapshotCase("dictionary-empty", model: { ScreenSamples.model() }) { DictionaryScreen() },
      SnapshotCase("dictionary-empty-phone", canvas: .phone, model: { ScreenSamples.model() }) {
        DictionaryScreen()
      },
      SnapshotCase("dictionary-long", model: { ScreenSamples.model(words: many) }) { DictionaryScreen() },
      SnapshotCase("dictionary-long-phone", canvas: .phone, model: { ScreenSamples.model(words: many) }) {
        DictionaryScreen()
      },
      SnapshotCase("dictionary-search", model: { ScreenSamples.model(words: many) }) {
        DictionaryScreen(preview: DictionaryPreview(query: "post"))
      },
      SnapshotCase("dictionary-no-results", model: { ScreenSamples.model(words: many) }) {
        DictionaryScreen(preview: DictionaryPreview(query: "giraffe"))
      },
      SnapshotCase("dictionary-add") {
        DictionaryScreen(
          preview: DictionaryPreview(editor: DictionaryEditor(text: "Saoirse", heardAs: "seer sha"))
        )
      },
      SnapshotCase("dictionary-add-phone", canvas: .phone) {
        DictionaryScreen(
          preview: DictionaryPreview(editor: DictionaryEditor(text: "Saoirse", heardAs: "seer sha"))
        )
      },
      SnapshotCase("dictionary-add-error") {
        DictionaryScreen(
          preview: DictionaryPreview(editor: DictionaryEditor(text: "kubernetes", heardAs: ""))
        )
      },
      SnapshotCase("dictionary-add-empty") {
        DictionaryScreen(preview: DictionaryPreview(editor: DictionaryEditor(text: "", showsProblems: true)))
      },
      SnapshotCase("dictionary-delete") {
        DictionaryScreen(
          preview: DictionaryPreview(deleting: DictionaryWord(text: "Kubernetes", replaces: "cooper netties"))
        )
      },
    ]
  }

  /// Enough words for the search field to show, with one very long entry.
  private static func manyWords(now: Date = Date()) -> [DictionaryWord] {
    let entries: [(String, String?)] = [
      ("Kubernetes", "cooper netties"), ("PostgreSQL", "post gres"), ("Priya Raman", nil),
      ("Spaces", "open whisper"), ("Northwind", nil), ("Zoë", "zoey"), ("Figma", nil),
      ("OAuth", "oh auth"), ("Reykjavík", "rake a vick"), ("Xcode", "ex code"), ("Tailscale", nil),
      (
        "Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch railway station",
        "that very long Welsh village name near the Menai Strait that nobody can spell"
      ),
      ("Grafana", nil), ("Nguyen", "win"),
    ]
    return entries.enumerated().map { index, entry in
      DictionaryWord(
        text: entry.0,
        replaces: entry.1,
        createdAt: now.addingTimeInterval(-Double(index) * 3_600)
      )
    }
  }
}
