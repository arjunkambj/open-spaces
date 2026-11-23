import SpacesDomain
import SpacesEngine
import SwiftUI

// Small pieces shared by the Meetings list and a meeting's page. Each one is built from the
// kit's tokens, for something the kit has no component for.

/// Sizes the Meetings screens need that are not gaps: column widths and fixed heights.
enum MeetingsMetrics {
  /// The column a speaker's name sits in, beside what was said.
  static let speakerColumn: CGFloat = 76
  /// The red dot of a live recording.
  static let recordingDot: CGFloat = 8
  /// The window onto the live transcript on the recording card: about four lines.
  static let liveLinesHeight: CGFloat = 100
  /// A grey bar that stands in for a line of text that is still being written.
  static let skeletonLine: CGFloat = 12
  /// The page gutter of `Page`, which a meeting's page repeats.
  static let gutter: CGFloat = 40
  /// The inline field a new tag is typed into, and the height of a tag.
  static let tagField: CGFloat = 110
  static let tagHeight: CGFloat = 24
  /// The side padding of a small button, by which the row of suggested questions is pulled left.
  static let suggestionInset: CGFloat = 11
  /// The least height of a checklist row.
  static let checklistRow: CGFloat = 48
  static let editorHeight: CGFloat = 400
}

/// What a snapshot can set up front, because it cannot click: the open tab, an open dialog,
/// text already typed. The app always uses the defaults.
struct MeetingsPreset {
  var tab: MeetingTab = .notes
  /// Text in the search field of the list.
  var query = ""
  /// Text in the find field of the transcript.
  var find = ""
  /// Opens the delete dialog: for the first meeting on the list, or for the open meeting.
  var confirmsDelete = false
  var editsTags = false
  var startFailure: SpacesError?
  var questions: MeetingQuestions?
  /// Opens the dialog that renames this speaker of the open meeting.
  var renamesSpeaker: Speaker?
}

enum MeetingTab: String, CaseIterable, Hashable {
  case notes, transcript, myNotes

  var title: String {
    switch self {
    case .notes: "Notes"
    case .transcript: "Transcript"
    case .myNotes: "My notes"
    }
  }
}

/// Things both the list and a meeting's page can do to a meeting.
@MainActor
enum MeetingActions {
  /// Copies notes or a transcript: what was said in a meeting is private.
  static func copy(_ text: String) {
    ScreenClipboard.copy(text)
  }

  /// Deletes the meeting. When it is the one being recorded, the recording stops too.
  static func delete(_ id: Meeting.ID, in model: AppModel) {
    model.run { model in
      try await model.library.deleteMeeting(id)
      if model.meetings.live?.meetingID == id { await model.meetings.stop() }
    }
  }

  /// Runs the remedy of a `MeetingProblem`.
  static func fix(_ remedy: MeetingProblem.Remedy, _ id: Meeting.ID, in model: AppModel) {
    switch remedy {
    case .retry: retry(id, in: model)
    case .writeNotes: writeNotes(id, in: model)
    }
  }

  static func writeNotes(_ id: Meeting.ID, in model: AppModel) {
    model.run { try await $0.meetings.regenerateNotes(id) }
  }

  /// Processes the meeting again. When that fails the engine writes the reason into the
  /// meeting, where the screens show it; only a reason that is not there is reported here.
  static func retry(_ id: Meeting.ID, in model: AppModel) {
    Task {
      do {
        try await model.meetings.retry(id)
      } catch {
        let stored = try? await model.library.meeting(id)
        if stored?.failure == nil { model.errorMessage = error.localizedDescription }
      }
    }
  }
}

/// The red dot, the word "Recording" and a running clock.
struct MeetingRecordingStamp: View {
  let startedAt: Date

  var body: some View {
    HStack(spacing: Spaces.Space.s) {
      Circle()
        .fill(Spaces.Color.recording)
        .frame(width: MeetingsMetrics.recordingDot, height: MeetingsMetrics.recordingDot)
        .accessibilityHidden(true)
      Text("Recording").spacesText(.captionStrong)
      TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
        Text(MeetingsLogic.clock(timeline.date.timeIntervalSince(startedAt)))
          .monospacedDigit()
          .spacesText(.caption)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// The live waveform of the meeting being recorded. A view of its own, so the level, which
/// changes many times a second, redraws nothing else.
struct MeetingLevelMeter: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Waveform(level: Double(model.meetings.level), bars: 11, tint: Spaces.Color.accent, height: 22)
  }
}

/// Text that turns into a field when clicked, and saves when Return is pressed or the
/// cursor leaves. Unlike a field, it wraps over several lines while it is only shown.
struct MeetingInlineText: View {
  let text: String
  let style: Spaces.TextStyle
  var color: SwiftUI.Color?
  var isStruckThrough = false
  /// What the text is, for VoiceOver: "Meeting title".
  let label: String
  /// Called with the new text, trimmed and not empty, when it changed.
  let onCommit: (String) -> Void

  @State private var draft = ""
  @State private var isEditing = false
  @FocusState private var isFocused: Bool

  var body: some View {
    if isEditing {
      TextField(label, text: $draft)
        .textFieldStyle(.plain)
        .spacesText(style)
        .focused($isFocused)
        .focusEffectDisabled()
        .onSubmit(commit)
        .onChange(of: isFocused) { _, focused in
          if !focused { commit() }
        }
        .onAppear { isFocused = true }
        .onExitCommand { isEditing = false }
        .accessibilityLabel(label)
    } else {
      Button {
        draft = text
        isEditing = true
      } label: {
        Text(text)
          .strikethrough(isStruckThrough)
          .spacesText(style, color: color)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Click to edit")
      .accessibilityLabel("\(label): \(text)")
      .accessibilityHint("Edits the text")
    }
  }

  private func commit() {
    guard isEditing else { return }
    isEditing = false
    let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    if !typed.isEmpty, typed != text { onCommit(typed) }
  }
}

/// Lays its children out in a line and starts a new line when the width runs out.
struct MeetingFlow: Layout {
  var spacing: CGFloat = Spaces.Space.s
  var lineSpacing: CGFloat = Spaces.Space.xs

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(subviews, width: proposal.width ?? .infinity).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let frames = arrange(subviews, width: bounds.width).frames
    for (subview, frame) in zip(subviews, frames) {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(frame.size)
      )
    }
  }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
    var frames: [CGRect] = []
    var line: [Int] = []
    var (x, y, widest) = (CGFloat.zero, CGFloat.zero, CGFloat.zero)

    // Centres the finished line's children on its tallest one and moves down past it.
    func endLine() {
      let height = line.map { frames[$0].height }.max() ?? 0
      for index in line { frames[index].origin.y = y + (height - frames[index].height) / 2 }
      if !line.isEmpty { y += height + lineSpacing }
      line = []
      x = 0
    }

    for subview in subviews {
      let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
      if x > 0, x + size.width > width { endLine() }
      line.append(frames.count)
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      widest = max(widest, x + size.width)
      x += size.width + spacing
    }
    endLine()
    return (frames, CGSize(width: widest, height: max(0, y - lineSpacing)))
  }
}

/// A quiet card that says work is going on.
struct MeetingProgressNote: View {
  let title: String
  let message: String

  var body: some View {
    Card(padding: Spaces.Space.l) {
      HStack(spacing: Spaces.Space.m) {
        ProcessingIndicator(tint: Spaces.Color.accent, height: 18)
        VStack(alignment: .leading, spacing: Spaces.Space.xxs) {
          Text(title).spacesText(.bodyStrong)
          Text(message)
            .spacesText(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// Shown while the library is still being read.
struct MeetingsLoading: View {
  var body: some View {
    ProcessingIndicator(tint: Spaces.Color.textTertiary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.vertical, Spaces.Space.xxxl)
  }
}

extension View {
  /// Asks a yes-or-no question before something that cannot be taken back, or that replaces work.
  func meetingConfirmDialog(
    isPresented: Binding<Bool>,
    title: String,
    message: String,
    confirm: String,
    isDestructive: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    dialog(isPresented: isPresented, title: title, width: 440) {
      Text(message)
        .spacesText(.body, color: Spaces.Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    } footer: {
      // Return presses the main button, but never one that deletes: then it presses Cancel.
      Button("Cancel") { isPresented.wrappedValue = false }
        .buttonStyle(.spaces())
        .keyboardShortcut(isDestructive ? .defaultAction : nil)
      Button(confirm) {
        action()
        isPresented.wrappedValue = false
      }
      .buttonStyle(.spaces(isDestructive ? .destructive : .primary))
      .keyboardShortcut(isDestructive ? nil : .defaultAction)
    }
  }

  /// Asks before a meeting is deleted. Shows while `meeting` holds one.
  func meetingDeleteDialog(_ meeting: Binding<Meeting?>, onDelete: @escaping (Meeting) -> Void) -> some View {
    let doomed = meeting.wrappedValue
    return meetingConfirmDialog(
      isPresented: Binding(
        get: { meeting.wrappedValue != nil },
        set: { if !$0 { meeting.wrappedValue = nil } }
      ),
      title: "Delete this meeting?",
      message: "“\(doomed?.title ?? "This meeting")” is removed from this device with its recording, "
        + "transcript and notes. This cannot be undone.",
      confirm: "Delete meeting"
    ) {
      if let doomed { onDelete(doomed) }
    }
  }
}
