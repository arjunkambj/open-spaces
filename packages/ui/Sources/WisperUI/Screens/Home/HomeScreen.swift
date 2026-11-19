import SwiftUI
import WisperDomain
import WisperEngine

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// Home: greeting, stats and the dictation history. Reads `AppModel` from the environment.
public struct HomeScreen: View {
  @Environment(AppModel.self) private var model
  @Environment(\.wisperIdiom) private var idiom
  @AppStorage("home.tipDismissed") private var tipDismissed = false

  @State private var query: String
  @State private var player: HomeAudioPlayer
  @State private var deleting: Dictation?
  @State private var isConfirmingDelete: Bool
  @State private var retryingID: Dictation.ID?
  @State private var limit = HomeHistory.pageSize
  @State private var toast: Toast?
  /// The width the content has. Decides whether the stats fit beside the history.
  @State private var width: CGFloat = HomeScreen.sideColumnBreakpoint
  private let preview: HomePreview

  /// The stats sit in a column beside the history from this content width up.
  private static let sideColumnBreakpoint: CGFloat = 720
  private static let sideColumnWidth: CGFloat = 250

  public init() {
    self.init(preview: HomePreview())
  }

  /// Starts in a given state, so snapshots can show it.
  init(preview: HomePreview) {
    self.preview = preview
    _query = State(initialValue: preview.query)
    _player = State(initialValue: preview.player ?? HomeAudioPlayer())
    _deleting = State(initialValue: preview.deleting)
    _isConfirmingDelete = State(initialValue: preview.deleting != nil)
  }

  public var body: some View {
    Page(title: HomeText.greeting(name: model.settings.userName), width: .wide) {
      Group {
        if idiom == .mac && width >= Self.sideColumnBreakpoint {
          HStack(alignment: .top, spacing: Wisper.Space.xl) {
            VStack(alignment: .leading, spacing: Wisper.Space.xl) {
              notice
              history
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HomeStats(layout: .card).frame(width: Self.sideColumnWidth)
          }
        } else {
          VStack(alignment: .leading, spacing: Wisper.Space.xl) {
            notice
            HomeStats(layout: .row)
            history
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        width = $0
      }
    }
    .toast($toast)
    .dialog(
      isPresented: $isConfirmingDelete,
      title: "Delete this dictation?",
      subtitle: deleting?.audioFile == nil
        ? "It is removed from your history. This cannot be undone."
        : "It is removed from your history, along with its recording. This cannot be undone."
    ) {
      if let deleting, !deleting.text.isEmpty {
        Card {
          Text(deleting.text).wisperText(.body).lineLimit(3)
        }
      }
    } footer: {
      Button("Cancel") { isConfirmingDelete = false }.buttonStyle(.wisper())
      Button("Delete") { confirmDelete() }.buttonStyle(.wisper(.destructive))
    }
    .onChange(of: query) { limit = HomeHistory.pageSize }
    .onDisappear { player.stop() }
  }

  // MARK: - Notice

  /// The key warning when there is no key, otherwise the how-to tip until it is dismissed.
  @ViewBuilder private var notice: some View {
    if model.isLoaded && !model.hasAPIKey {
      Banner(
        .warning,
        title: "Add your OpenAI key to start dictating",
        message: "Open Settings, choose OpenAI and paste your key. It stays on this device."
      )
    } else if !tipDismissed {
      tip
    }
  }

  @ViewBuilder private var tip: some View {
    let keys = HomeText.keyLabels(model.settings.shortcut(for: .pushToTalk))
    if idiom == .phone {
      HeroCard(
        "Talk instead of typing",
        message: "Tap the record button and speak. Your words come out as clean text."
      )
      .onDismiss { tipDismissed = true }
    } else if keys.isEmpty {
      HeroCard(
        "Talk instead of typing",
        message: "Choose a push-to-talk shortcut in Settings. Then hold it and speak in any app."
      )
      .onDismiss { tipDismissed = true }
    } else {
      HeroCard("Talk instead of typing") {
        Text("Hold").wisperText(.body, color: Wisper.Color.textSecondary)
        KeyCapRow(keys)
        Text("and speak in any app.").wisperText(.body, color: Wisper.Color.textSecondary)
      }
      .onDismiss { tipDismissed = true }
      .accessibilityElement(children: .contain)
    }
  }

  // MARK: - History

  @ViewBuilder private var history: some View {
    if !model.isLoaded {
      VStack(spacing: Wisper.Space.m) {
        ProcessingIndicator(tint: Wisper.Color.textTertiary)
        Text("Loading your history…").wisperText(.caption)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.vertical, Wisper.Space.xxxl)
    } else if model.dictations.isEmpty {
      emptyHistory
    } else {
      let matching = HomeHistory.filter(model.dictations, query: query)
      let days = HomeHistory.days(Array(matching.prefix(limit)))
      if idiom == .phone {
        SearchField(text: $query, placeholder: "Search your dictations")
      }
      // The first day is laid out by hand so the search field keeps its place (and the
      // cursor) while the results under it change.
      VStack(alignment: .leading, spacing: Wisper.Space.m) {
        HStack(spacing: Wisper.Space.s) {
          SectionLabel(days.first?.title ?? "No matches")
          Spacer(minLength: 0)
          if idiom == .mac {
            SearchField(text: $query, placeholder: "Search your dictations")
          }
        }
        .frame(minHeight: idiom == .mac ? Self.headerHeight : nil)
        if let first = days.first {
          rows(first)
        } else {
          EmptyState(
            "Nothing matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”",
            message: "Try another word, or the name of the app you were in."
          ) {
            SymbolTile("magnifyingglass")
          } action: {
            Button("Clear search") { query = "" }.buttonStyle(.wisper(.tertiary))
          }
        }
      }
      ForEach(days.dropFirst()) { day in
        PageSection(day.title) { rows(day) }
      }
      if matching.count > limit {
        Button("Show older dictations") { limit += HomeHistory.pageSize }
          .buttonStyle(.wisper(.tertiary))
          .frame(maxWidth: .infinity)
      }
    }
  }

  /// The height of a section header that holds a control, as in the kit's `PageSection`.
  private static let headerHeight: CGFloat = 32

  private func rows(_ day: HomeHistoryDay) -> some View {
    let canRetry = !isWorking(model.dictation.phase)
    let hovered = preview.hoveredRow.flatMap { day.entries.indices.contains($0) ? day.entries[$0].id : nil }
    return CardList(day.entries, style: .filled) { dictation in
      HomeDictationRow(
        dictation: dictation,
        player: player,
        isRetrying: retryingID == dictation.id,
        canRetry: canRetry && retryingID == nil,
        actions: HomeRowActions(
          copy: { copy(dictation) },
          togglePlayback: { togglePlayback(dictation) },
          retry: { retry(dictation) },
          delete: {
            deleting = dictation
            isConfirmingDelete = true
          }
        )
      )
      .environment(\.simulatedHover, hovered == dictation.id)
    }
  }

  /// Recording or making text: a retry cannot start until that is over.
  private func isWorking(_ phase: DictationEngine.Phase) -> Bool {
    switch phase {
    case .recording, .processing: true
    case .idle, .failed: false
    }
  }

  @ViewBuilder private var emptyHistory: some View {
    if model.settings.historyRetention == .never {
      EmptyState(
        "History is off",
        message: "Your dictations are not being kept. You can change this in Settings, under Privacy & data."
      ) {
        SymbolTile("clock.badge.xmark")
      }
    } else {
      EmptyState("No dictations yet", message: firstDictationHint) {
        SymbolTile("waveform")
      }
    }
  }

  private var firstDictationHint: String {
    if idiom == .phone {
      return "Tap the record button and speak. What you say is saved here."
    }
    let keys = HomeText.keyLabels(model.settings.shortcut(for: .pushToTalk))
    if keys.isEmpty {
      return "Choose a push-to-talk shortcut in Settings, then hold it and speak. What you say is saved here."
    }
    return
      "Click where you want to type, hold \(keys.joined(separator: " ")) and speak. What you say is saved here."
  }

  // MARK: - Actions

  private func copy(_ dictation: Dictation) {
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(dictation.text, forType: .string)
    #elseif canImport(UIKit)
      UIPasteboard.general.string = dictation.text
    #endif
    toast = Toast("Copied")
  }

  private func togglePlayback(_ dictation: Dictation) {
    guard let name = dictation.audioFile else { return }
    if player.playingID == dictation.id {
      player.stop()
      return
    }
    Task {
      do {
        let folder = try await model.library.dictationAudioDirectory()
        // Only ever a file inside the audio folder, whatever the entry says.
        let file = folder.appendingPathComponent((name as NSString).lastPathComponent)
        guard FileManager.default.fileExists(atPath: file.path) else {
          toast = Toast("The recording is no longer on this device.", tone: .error)
          return
        }
        try player.play(dictation.id, file: file)
      } catch {
        toast = Toast("The recording could not be played.", tone: .error)
      }
    }
  }

  private func retry(_ dictation: Dictation) {
    guard retryingID == nil else { return }
    retryingID = dictation.id
    Task {
      let result = await model.dictation.retry(dictation.id)
      retryingID = nil
      toast =
        result == nil
        ? Toast("That did not work. Try again in a moment.", tone: .error)
        : Toast("Done. Your text is ready.")
    }
  }

  private func confirmDelete() {
    isConfirmingDelete = false
    guard let id = deleting?.id else { return }
    if player.playingID == id { player.stop() }
    model.run { try await $0.library.deleteDictations([id]) }
  }
}

/// A starting state for `HomeScreen`, so snapshots can show what needs a click or a pointer.
struct HomePreview {
  var query = ""
  /// The row of each day drawn as if the pointer were over it, counted from the top.
  var hoveredRow: Int?
  /// The entry whose delete question is open.
  var deleting: Dictation?
  var player: HomeAudioPlayer?
}
