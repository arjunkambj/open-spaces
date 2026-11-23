import SpacesDomain
import SpacesEngine
import SwiftUI

/// The Transcript tab: who said what, in order, with the text being looked for marked.
struct MeetingTranscriptTab: View {
  let turns: [TranscriptTurn]
  let phase: MeetingPhase
  let matches: [TranscriptMatch]
  let currentMatch: TranscriptMatch?
  /// Asks for a new name for a speaker, from their name in the transcript. `nil` while the
  /// transcript is still being written, when no speaker can be renamed.
  var onRename: ((Speaker) -> Void)?

  var body: some View {
    if turns.isEmpty {
      empty
    } else {
      // Lazy: a long meeting has hundreds of turns.
      LazyVStack(alignment: .leading, spacing: Spaces.Space.l) {
        ForEach(turns) { turn in
          MeetingTurnRow(
            turn: turn,
            matches: matches.filter { $0.turn == turn.id },
            currentMatch: currentMatch?.turn == turn.id ? currentMatch : nil,
            onRename: turn.speaker == .me ? nil : onRename
          )
        }
        if phase == .live {
          HStack(spacing: Spaces.Space.s) {
            ProcessingIndicator(tint: Spaces.Color.accent, height: 14)
            Text("Listening…").spacesText(.caption)
          }
        }
      }
    }
  }

  @ViewBuilder private var empty: some View {
    switch phase {
    case .live:
      EmptyState(
        "Listening…",
        message: "The first lines show up about half a minute after someone starts talking."
      ) {
        MeetingLevelMeter()
      }
    case .processing:
      MeetingProgressNote(
        title: "Writing the transcript…",
        message: "This takes a moment. You can leave this page."
      )
    case .failed, .interrupted:
      EmptyState("No transcript yet", message: "Use the button above to try again.") {
        SymbolTile("text.quote")
      }
    case .ready:
      EmptyState("No transcript", message: "No speech was heard in this meeting.") {
        SymbolTile("text.quote")
      }
    }
  }
}

/// What one speaker said in one go: the name and the time on the side, the words beside them.
private struct MeetingTurnRow: View {
  let turn: TranscriptTurn
  let matches: [TranscriptMatch]
  let currentMatch: TranscriptMatch?
  /// Set when the speaker can be renamed: their name is then a button.
  let onRename: ((Speaker) -> Void)?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Spaces.Space.l) {
      who
      Text(marked)
        .spacesText(.body)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
    .accessibilityActions {
      if let onRename {
        Button("Rename \(turn.speaker.label)") { onRename(turn.speaker) }
      }
    }
  }

  private var who: some View {
    let label = Text(turn.speaker.label)
      .spacesText(
        .captionStrong,
        color: turn.speaker == .me ? Spaces.Color.accent : Spaces.Color.textPrimary
      )
      .lineLimit(1)
    let name = Group {
      if let onRename {
        Button {
          onRename(turn.speaker)
        } label: {
          label
        }
        .buttonStyle(.plain)
        .help("Rename this speaker")
      } else {
        label
      }
    }
    let time = Text(MeetingsLogic.clock(turn.start))
      .monospacedDigit()
      .spacesText(.caption, color: Spaces.Color.textTertiary)
    return VStack(alignment: .leading, spacing: Spaces.Space.xxs) {
      name
      time
    }
    .frame(width: MeetingsMetrics.speakerColumn, alignment: .leading)
  }

  /// The turn's text as one paragraph, with every match tinted and the current one filled.
  private var marked: AttributedString {
    var whole = AttributedString()
    for (index, segment) in turn.segments.enumerated() {
      var piece = AttributedString(segment.text)
      for match in matches where match.segment == segment.id {
        guard let place = Range(match.range, in: piece) else { continue }
        if match == currentMatch {
          piece[place].backgroundColor = Spaces.Color.accent
          piece[place].foregroundColor = Spaces.Color.onAccent
        } else {
          piece[place].backgroundColor = Spaces.Color.accent.opacity(0.2)
        }
      }
      if index > 0 { whole += AttributedString(" ") }
      whole += piece
    }
    return whole
  }
}

/// The find field under the transcript, with the place among the matches and the buttons
/// to move between them. It stays put while the transcript scrolls.
struct MeetingFindBar: View {
  @Binding var text: String
  /// Whether the matches are those of some text. False while there is none, when no count shows.
  let isSearching: Bool
  /// How many matches there are, and which one is current (from 0).
  let count: Int
  let index: Int
  /// Moves forward (`1`) or back (`-1`).
  let onStep: (Int) -> Void
  let onCopy: () -> Void

  var body: some View {
    MeetingBottomBar {
      HStack(spacing: Spaces.Space.xs) {
        SpacesTextField(text: $text, placeholder: "Find in transcript")
          .onSubmit { onStep(1) }
        if isSearching {
          Text(count == 0 ? "No matches" : "\(index + 1) of \(count)")
            .monospacedDigit()
            .spacesText(.caption)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Spaces.Space.xs)
          IconButton("chevron.up", label: "Previous match") { onStep(-1) }
            .disabled(count < 2)
          IconButton("chevron.down", label: "Next match") { onStep(1) }
            .disabled(count < 2)
        }
        IconButton("doc.on.doc", label: "Copy transcript", action: onCopy)
      }
    }
  }
}

// MARK: - My notes

/// The user's own notes: a plain text box that saves by itself a moment after typing stops.
struct MeetingMyNotesTab: View {
  let meeting: Meeting

  @Environment(AppModel.self) private var model
  @State private var draft: String
  /// What the library holds, as far as this view knows.
  @State private var saved: String
  @State private var showsSaved = false

  init(meeting: Meeting) {
    self.meeting = meeting
    _draft = State(initialValue: meeting.userNotes)
    _saved = State(initialValue: meeting.userNotes)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spaces.Space.s) {
      SpacesTextEditor(
        text: $draft,
        placeholder: "Write anything you want to keep from this meeting.",
        height: MeetingsMetrics.editorHeight
      )
      HStack(spacing: Spaces.Space.s) {
        Text("Saved as you type.")
          .spacesText(.caption, color: Spaces.Color.textTertiary)
        Spacer(minLength: 0)
        if showsSaved {
          Label("Saved", systemImage: "checkmark")
            .spacesText(.caption, color: Spaces.Color.textTertiary)
            .transition(.opacity)
        }
      }
    }
    .animation(Spaces.Motion.smooth, value: showsSaved)
    .task(id: draft) {
      guard draft != saved else { return }
      showsSaved = false
      try? await Task.sleep(for: .milliseconds(700))
      if !Task.isCancelled { await save() }
    }
    .onChange(of: meeting.userNotes) { _, stored in
      // Someone else (an agent) changed the notes. Take them unless the user is mid-edit.
      if draft == saved { draft = stored }
      saved = stored
    }
    .onDisappear {
      guard draft != saved else { return }
      let (id, text) = (meeting.id, draft)
      model.run { _ = try await $0.library.updateMeeting(id) { $0.userNotes = text } }
    }
  }

  private func save() async {
    let (id, text) = (meeting.id, draft)
    let done = await model.attempt { _ = try await $0.library.updateMeeting(id) { $0.userNotes = text } }
    if done {
      saved = text
      showsSaved = true
    }
  }
}
