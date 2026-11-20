import SpacesDomain
import SpacesEngine
import SwiftUI

/// Home: how to dictate, the numbers in one line, and the dictation history.
/// Reads `AppModel` from the environment.
public struct HomeScreen: View {
  @Environment(AppModel.self) private var model
  @Environment(\.spacesIdiom) private var idiom

  @State private var query: String
  @State private var player: HomeAudioPlayer
  @State private var deleting: Dictation?
  @State private var isConfirmingDelete: Bool
  @State private var retryingID: Dictation.ID?
  @State private var limit = HomeHistory.pageSize
  @State private var toast: Toast?
  private let preview: HomePreview
  private let showAgents: (() -> Void)?

  /// - showAgents: opens Settings › Agents, when the line that says which AI tool is connected
  ///   is clicked. `nil` leaves the line as plain text.
  public init(showAgents: (() -> Void)? = nil) {
    self.init(preview: HomePreview(), showAgents: showAgents)
  }

  /// Starts in a given state, so snapshots can show it.
  init(preview: HomePreview, showAgents: (() -> Void)? = nil) {
    self.preview = preview
    self.showAgents = showAgents
    _query = State(initialValue: preview.query)
    _player = State(initialValue: preview.player ?? HomeAudioPlayer())
    _deleting = State(initialValue: preview.deleting)
    _isConfirmingDelete = State(initialValue: preview.deleting != nil)
  }

  public var body: some View {
    Page(title: HomeText.title(idiom)) {
      if idiom == .mac, model.isLoaded, !model.dictations.isEmpty {
        SearchField(text: $query, placeholder: "Search your dictations")
      }
    } content: {
      notice
      history
    }
    .titleAccessory { HomeSummary(showAgents: showAgents) }
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
          Text(deleting.text).spacesText(.body).lineLimit(3)
        }
      }
    } footer: {
      // Return must never delete: it presses Cancel.
      Button("Cancel") { isConfirmingDelete = false }.buttonStyle(.spaces()).keyboardShortcut(.defaultAction)
      Button("Delete") { confirmDelete() }.buttonStyle(.spaces(.destructive))
    }
    .onChange(of: query) { limit = HomeHistory.pageSize }
    .onDisappear { player.stop() }
  }

  // MARK: - Notice

  /// Said only while it is true: without a key nothing can be turned into text.
  @ViewBuilder private var notice: some View {
    if model.isLoaded && KeyNeed.isMissing(hasKey: model.hasAPIKey, settings: model.settings) {
      Banner(
        .warning,
        title: "Add your OpenAI key to start dictating",
        message: "Open Settings, choose OpenAI and paste your key. It stays on this device."
      )
    }
  }

  // MARK: - History

  @ViewBuilder private var history: some View {
    if !model.isLoaded {
      VStack(spacing: Spaces.Space.m) {
        ProcessingIndicator(tint: Spaces.Color.textTertiary)
        Text("Loading your history…").spacesText(.caption)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.vertical, Spaces.Space.xxxl)
    } else if model.dictations.isEmpty {
      emptyHistory
    } else {
      let matching = HomeHistory.filter(model.dictations, query: query)
      let days = HomeHistory.days(Array(matching.prefix(limit)))
      if idiom == .phone {
        SearchField(text: $query, placeholder: "Search your dictations")
      }
      if days.isEmpty {
        EmptyState(
          "Nothing matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”",
          message: "Try another word, or the name of the app you were in."
        ) {
          SymbolTile("magnifyingglass")
        } action: {
          Button("Clear search") { query = "" }.buttonStyle(.spaces(.tertiary))
        }
      }
      ForEach(days) { day in
        PageSection(day.title) { rows(day) }
      }
      if matching.count > limit {
        Button("Show older dictations") { limit += HomeHistory.pageSize }
          .buttonStyle(.spaces(.tertiary))
          .frame(maxWidth: .infinity)
      }
    }
  }

  private func rows(_ day: HomeHistoryDay) -> some View {
    let canRetry = !isWorking(model.dictation.phase)
    let hovered = preview.hoveredRow.flatMap { day.entries.indices.contains($0) ? day.entries[$0].id : nil }
    return CardList(day.entries) { dictation in
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
        message: "Your dictations are not being kept. You can change this in Settings, under Privacy."
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
      return "What you dictate shows up here."
    }
    let keys = HomeText.keyLabels(model.settings.shortcut(for: .pushToTalk))
    if keys.isEmpty {
      return "Choose a push-to-talk shortcut in Settings, then hold it and speak. What you say shows up here."
    }
    return "Click where you want to type, hold \(keys.joined(separator: " ")) and speak. "
      + "What you say shows up here."
  }

  // MARK: - Actions

  private func copy(_ dictation: Dictation) {
    ScreenClipboard.copy(dictation.text, as: .personal)
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
      // Home is in front, so no other app is waiting for this text: it is saved and copied,
      // never typed somewhere. When it fails again, the row goes on saying why.
      let outcome = HomeRetry(await model.dictation.retry(dictation.id, insert: false))
      retryingID = nil
      if let text = outcome.textToCopy { ScreenClipboard.copy(text, as: .personal) }
      toast = outcome.toast
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

/// The line under the title: how to dictate on a Mac, and the numbers so far. On a Mac, a
/// quiet line under it says which AI tool is connected, once one has used Spaces.
///
/// It is its own view so the numbers are worked out when the history changes, not on every
/// key typed into the search field.
private struct HomeSummary: View {
  let showAgents: (() -> Void)?

  @Environment(AppModel.self) private var model
  @Environment(\.spacesIdiom) private var idiom

  var body: some View {
    let numbers = model.isLoaded ? HomeText.summary(model.stats) : nil
    if idiom == .phone {
      if let numbers { Text(numbers).spacesText(.body, color: Spaces.Color.textSecondary) }
    } else {
      VStack(alignment: .leading, spacing: Spaces.Space.s) {
        // Side by side when they fit; the numbers go under the hint in a narrow window.
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .center, spacing: Spaces.Space.l) {
            hint
            Spacer(minLength: Spaces.Space.l)
            if let numbers {
              Text(numbers).spacesText(.caption, color: Spaces.Color.textTertiary).fixedSize()
            }
          }
          VStack(alignment: .leading, spacing: Spaces.Space.s) {
            hint
            if let numbers { Text(numbers).spacesText(.caption, color: Spaces.Color.textTertiary) }
          }
        }
        HomeAgentLine(sessions: model.agentSessions, open: showAgents)
      }
    }
  }

  /// "Hold fn to dictate in any app", with the keys drawn as keys. It follows the shortcuts.
  @ViewBuilder private var hint: some View {
    let hold = HomeText.keyLabels(model.settings.shortcut(for: .pushToTalk))
    let handsFree = HomeText.keyLabels(model.settings.shortcut(for: .handsFree))
    if hold.isEmpty && handsFree.isEmpty {
      Text("Choose a shortcut in Settings to start dictating.")
        .spacesText(.body, color: Spaces.Color.textSecondary)
    } else {
      HStack(spacing: Spaces.Space.s) {
        if !hold.isEmpty {
          Text("Hold").spacesText(.body, color: Spaces.Color.textSecondary)
          KeyCapRow(hold)
          Text(handsFree.isEmpty ? "and speak in any app." : "and speak, or press")
            .spacesText(.body, color: Spaces.Color.textSecondary)
        } else {
          Text("Press").spacesText(.body, color: Spaces.Color.textSecondary)
        }
        if !handsFree.isEmpty {
          KeyCapRow(handsFree)
          Text("to talk hands-free.").spacesText(.body, color: Spaces.Color.textSecondary)
        }
      }
      .fixedSize()
      .accessibilityElement(children: .combine)
    }
  }
}

/// "Claude Code is connected", with a dot that is filled while it is. Nothing at all when no
/// AI tool has used Spaces in the last day. The time in it moves on by itself.
private struct HomeAgentLine: View {
  let sessions: [AgentSession]
  let open: (() -> Void)?

  @State private var isHovered = false

  var body: some View {
    let tools = AgentStatus.list(sessions)
    if !tools.isEmpty {
      TimelineView(.periodic(from: .now, by: 60)) { timeline in
        if let text = AgentStatus.homeLine(tools, now: timeline.date) {
          let connected = tools.contains(where: \.isConnected)
          if let open {
            Button(action: open) { label(text, connected: connected) }
              .buttonStyle(.plain)
              .onHover { isHovered = $0 }
              .help("See your AI tools in Settings")
              .accessibilityHint("Opens Settings, Agents.")
          } else {
            label(text, connected: connected)
          }
        }
      }
    }
  }

  private func label(_ text: String, connected: Bool) -> some View {
    HStack(spacing: Spaces.Space.s) {
      AgentDot(isConnected: connected)
      Text(text)
        .spacesText(.caption, color: isHovered ? Spaces.Color.textPrimary : Spaces.Color.textTertiary)
        .lineLimit(1)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}
