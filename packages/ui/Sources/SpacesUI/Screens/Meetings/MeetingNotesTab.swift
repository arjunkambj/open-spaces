import SpacesDomain
import SpacesEngine
import SwiftUI

/// The Notes tab: what the language model wrote about the meeting, the action items as a
/// checklist, and the questions asked about it.
struct MeetingNotesTab: View {
  let meeting: Meeting
  let phase: MeetingPhase
  let thread: [MeetingQuestions.Entry]
  /// Changes the stored meeting.
  let edit: (@escaping @Sendable (inout Meeting) -> Void) -> Void
  let onDeleteItem: (ActionItem) -> Void
  let onAskAgain: (MeetingQuestions.Entry.ID) -> Void

  @Environment(AppModel.self) private var model

  var body: some View {
    if let notes = meeting.notes {
      if phase == .processing {
        MeetingProgressNote(
          title: "Writing the notes again…",
          message: "The notes below are replaced when the new ones are ready."
        )
      }
      if !notes.summary.isEmpty {
        PageSection("Summary") {
          Text(notes.summary)
            .spacesText(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if !notes.keyPoints.isEmpty {
        PageSection("Key points") { MeetingBullets(lines: notes.keyPoints) }
      }
      if !notes.decisions.isEmpty {
        PageSection("Decisions") { MeetingBullets(lines: notes.decisions) }
      }
      MeetingActionItems(items: notes.actionItems, edit: edit, onDelete: onDeleteItem)
    } else {
      missing
    }
    if !thread.isEmpty {
      PageSection("Questions") {
        VStack(alignment: .leading, spacing: Spaces.Space.m) {
          ForEach(thread) { entry in
            MeetingAnswer(entry: entry) { onAskAgain(entry.id) }
              .id(entry.id)
          }
        }
      }
    }
  }

  /// What stands in for notes that are not there, and why they are not.
  @ViewBuilder private var missing: some View {
    switch phase {
    case .live:
      EmptyState(
        "Notes come after the meeting",
        message: "Stop the recording and Spaces writes a summary, the decisions and the action items."
      ) {
        SymbolTile("list.bullet.clipboard")
      }
    case .processing:
      MeetingProgressNote(
        title: "Writing notes…",
        message: "This takes a moment. You can read the transcript while you wait, or leave this page."
      )
      MeetingSkeleton()
    case .failed, .interrupted:
      EmptyState("No notes yet", message: "Notes are written once the meeting has a transcript.") {
        SymbolTile("list.bullet.clipboard")
      }
    case .ready:
      if meeting.segments.isEmpty {
        EmptyState("Nothing to write notes from", message: "No speech was heard in this meeting.") {
          SymbolTile("list.bullet.clipboard")
        }
      } else {
        EmptyState(
          "No notes yet",
          message: "Spaces can write a summary, the decisions and the action items from the transcript."
        ) {
          SymbolTile("list.bullet.clipboard")
        } action: {
          Button("Write notes") { MeetingActions.writeNotes(meeting.id, in: model) }
            .buttonStyle(.spaces(.primary))
        }
      }
    }
  }
}

private struct MeetingBullets: View {
  let lines: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: Spaces.Space.s) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        HStack(alignment: .firstTextBaseline, spacing: Spaces.Space.m) {
          Text("•")
            .spacesText(.body, color: Spaces.Color.textTertiary)
            .accessibilityHidden(true)
          Text(line)
            .spacesText(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

/// Grey bars where the notes will be.
private struct MeetingSkeleton: View {
  var body: some View {
    VStack(alignment: .leading, spacing: Spaces.Space.xl) {
      ForEach([[0.8, 0.74, 0.5], [0.4, 0.58, 0.34]], id: \.self) { widths in
        VStack(alignment: .leading, spacing: Spaces.Space.m) {
          ForEach(widths, id: \.self) { width in
            RoundedRectangle(cornerRadius: Spaces.Radius.small, style: .continuous)
              .fill(Spaces.Color.surfaceSelected)
              .frame(height: MeetingsMetrics.skeletonLine)
              .frame(maxWidth: .infinity)
              .scaleEffect(x: width, anchor: .leading)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityHidden(true)
  }
}

// MARK: - Action items

/// The action items as a checklist that can be ticked, reworded, added to and trimmed.
private struct MeetingActionItems: View {
  let items: [ActionItem]
  let edit: (@escaping @Sendable (inout Meeting) -> Void) -> Void
  let onDelete: (ActionItem) -> Void

  @State private var draft = ""

  var body: some View {
    PageSection("Action items") {
      VStack(alignment: .leading, spacing: Spaces.Space.m) {
        if !items.isEmpty {
          CardList(items) { item in
            MeetingActionItemRow(item: item) {
              change(item.id) { $0.done = !item.done }
            } onRename: { text in
              change(item.id) { $0.text = text }
            } onDelete: {
              onDelete(item)
            }
          }
        }
        HStack(spacing: Spaces.Space.s) {
          SpacesTextField(text: $draft, placeholder: "Add an action item")
            .onSubmit(add)
          Button("Add", action: add)
            .buttonStyle(.spaces())
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    } trailing: {
      if !items.isEmpty {
        Text("\(items.filter(\.done).count) of \(items.count) done").spacesText(.caption)
      }
    }
  }

  private func change(_ id: ActionItem.ID, _ change: @escaping @Sendable (inout ActionItem) -> Void) {
    edit { meeting in
      guard var notes = meeting.notes, let index = notes.actionItems.firstIndex(where: { $0.id == id })
      else { return }
      change(&notes.actionItems[index])
      meeting.notes = notes
    }
  }

  private func add() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    draft = ""
    edit { meeting in
      var notes = meeting.notes ?? MeetingNotes()
      notes.actionItems.append(ActionItem(text: text))
      meeting.notes = notes
    }
  }
}

private struct MeetingActionItemRow: View {
  let item: ActionItem
  let onToggle: () -> Void
  let onRename: (String) -> Void
  let onDelete: () -> Void

  @Environment(\.spacesIdiom) private var idiom
  @Environment(\.simulatedHover) private var simulatedHover
  @State private var isHovered = false
  /// Whether the keyboard is on one of the row's controls.
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(alignment: .center, spacing: Spaces.Space.m) {
      Button(action: onToggle) {
        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
          .spacesText(.cardTitle, color: item.done ? Spaces.Color.accent : Spaces.Color.textTertiary)
          .frame(minWidth: Spaces.Space.xl, minHeight: Spaces.Space.xl)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(item.done ? "Done: \(item.text)" : "Not done: \(item.text)")
      .accessibilityHint(item.done ? "Marks it as not done" : "Marks it as done")
      MeetingInlineText(
        text: item.text,
        style: .body,
        color: item.done ? Spaces.Color.textSecondary : nil,
        isStruckThrough: item.done,
        label: "Action item",
        onCommit: onRename
      )
      if let owner = item.owner, !owner.isEmpty { Badge(owner) }
      IconButton("trash", label: "Delete this action item", size: .small, action: onDelete)
        // Tab reaches the button even while it is unseen, so it shows for the keyboard too.
        .opacity(idiom == .phone || isHovered || simulatedHover || isFocused ? 1 : 0)
    }
    .focused($isFocused)
    .padding(.vertical, Spaces.Space.s)
    .frame(minHeight: MeetingsMetrics.checklistRow(idiom))
    .rowChrome(isHighlighted: false)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .animation(Spaces.Motion.quick, value: isHovered)
    .animation(Spaces.Motion.quick, value: isFocused)
  }
}

// MARK: - Questions

/// One question and what came back.
private struct MeetingAnswer: View {
  let entry: MeetingQuestions.Entry
  let onAskAgain: () -> Void

  var body: some View {
    Card(.outlined, padding: Spaces.Space.l) {
      VStack(alignment: .leading, spacing: Spaces.Space.s) {
        Text(entry.question)
          .spacesText(.bodyStrong)
          .fixedSize(horizontal: false, vertical: true)
        switch entry.reply {
        case .waiting:
          HStack(spacing: Spaces.Space.s) {
            ProcessingIndicator(tint: Spaces.Color.accent, height: 14)
            Text("Reading the meeting…").spacesText(.caption)
          }
        case .answer(let text):
          Text(text)
            .spacesText(.body, color: Spaces.Color.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        case .failed(let reason):
          Text(reason)
            .spacesText(.caption, color: Spaces.Color.danger)
            .fixedSize(horizontal: false, vertical: true)
          Button("Ask again", action: onAskAgain)
            .buttonStyle(.spaces(.tertiary, size: .small))
        }
      }
    }
  }
}

/// The strip under a meeting's page that holds the ask field or the find field.
struct MeetingBottomBar<Content: View>: View {
  @ViewBuilder let content: Content
  @Environment(\.spacesIdiom) private var idiom

  var body: some View {
    VStack(alignment: .leading, spacing: Spaces.Space.s) { content }
      .frame(maxWidth: idiom == .phone ? .infinity : PageWidth.regular.points, alignment: .leading)
      .padding(.horizontal, MeetingsMetrics.gutter(idiom))
      .padding(.vertical, Spaces.Space.m)
      .frame(maxWidth: .infinity)
      .background { Spaces.Color.panel.ignoresSafeArea(edges: .bottom) }
      .overlay(alignment: .top) { Hairline() }
  }
}

/// The field for asking about the meeting, with ready-made questions before the first one.
struct MeetingAskBar: View {
  let showsSuggestions: Bool
  let isWaiting: Bool
  let onAsk: (String) -> Void

  @State private var question = ""
  @Environment(\.spacesIdiom) private var idiom

  var body: some View {
    MeetingBottomBar {
      if showsSuggestions {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: Spaces.Space.xxs) {
            ForEach(MeetingsLogic.suggestedQuestions, id: \.self) { suggestion in
              Button(suggestion) { onAsk(suggestion) }
                .buttonStyle(.spaces(.ghost, size: .small))
            }
          }
          // The words of the first one line up with the field under them.
          .padding(.leading, -MeetingsMetrics.suggestionInset(idiom))
        }
        .disabled(isWaiting)
      }
      HStack(spacing: Spaces.Space.s) {
        SpacesTextField(text: $question, placeholder: "Ask anything about this meeting")
          .onSubmit(send)
        Button(action: send) {
          Image(systemName: "arrow.up")
        }
        .buttonStyle(.spaces(.primary))
        .disabled(isWaiting || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel("Ask")
      }
    }
  }

  private func send() {
    let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isWaiting else { return }
    question = ""
    onAsk(text)
  }
}
