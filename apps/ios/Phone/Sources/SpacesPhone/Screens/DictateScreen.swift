import SpacesDomain
import SpacesEngine
import SpacesUI
import SwiftUI

/// The heart of the phone app: one big button. Tap it and speak, tap again, and the text is
/// on the clipboard and on this screen, ready to copy, share or fix.
///
/// Reads `AppModel` and `PhoneSession` from the environment.
public struct DictateScreen: View {
  @Environment(PhoneSession.self) private var session
  @Environment(\.phoneDevice) private var device
  @Environment(\.scenePhase) private var scenePhase

  @State private var toast: Toast?
  @State private var editing: Dictation?
  @State private var draft = ""

  public init() {}

  public var body: some View {
    let dictation = session.dictation
    Page(title: "Dictate") {
      if let problem = dictation.problem {
        ProblemBanner(problem: problem)
      }
      if let result = dictation.result {
        ResultCard(dictation: result) { begin(editing: result) }
      } else if dictation.earlier.isEmpty, dictation.problem == nil {
        EmptyState(
          "Say it instead of typing it",
          message:
            "Tap the button and speak. Spaces writes it down and copies it, ready to paste anywhere."
        ) {
          SymbolTile("waveform")
        }
      }
      if !dictation.earlier.isEmpty {
        PageSection("Earlier") {
          CardList(dictation.earlier) { entry in
            ListRow(entry.text, subtitle: entry.createdAt.formatted(.relative(presentation: .named))) {
            } hoverActions: {
              IconButton("doc.on.doc", label: "Copy") { dictation.copy(entry) }
            }
            .onTap { dictation.copy(entry) }
            .lineLimit(2)
          }
        } trailing: {
          Button("All history") { session.tab = .history }
            .buttonStyle(.spaces(.ghost, size: .small))
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) { RecordDock() }
    .toast($toast)
    .dialog(isPresented: isEditing, title: "Edit text", subtitle: "The fixed text is copied when you save.") {
      SpacesTextEditor(text: $draft, height: 180)
    } footer: {
      Button("Cancel") { editing = nil }
        .buttonStyle(.spaces())
      Button("Save") { saveEdit() }
        .buttonStyle(.spaces(.primary))
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .onChange(of: dictation.copies) {
      toast = Toast("Copied to clipboard")
    }
    .onChange(of: dictation.isRecording, initial: true) { _, isRecording in
      // A phone that locks in the middle of a sentence is no help.
      device.keepAwake(isRecording)
    }
    .onChange(of: scenePhase, initial: true) {
      // The person may be back from the Settings app with the microphone turned on.
      dictation.refresh()
    }
    .onDisappear { device.keepAwake(false) }
    .sensoryFeedback(trigger: dictation.isRecording) { _, isRecording in
      .impact(weight: isRecording ? .medium : .light)
    }
    .sensoryFeedback(.success, trigger: dictation.copies)
  }

  private var isEditing: Binding<Bool> {
    Binding(
      get: { editing != nil },
      set: { open in
        if !open { editing = nil }
      }
    )
  }

  private func begin(editing dictation: Dictation) {
    draft = dictation.text
    editing = dictation
  }

  private func saveEdit() {
    guard let dictation = editing else { return }
    let text = draft
    editing = nil
    Task { await session.dictation.save(text, for: dictation) }
  }
}

/// The newest text, with the things a person does with it.
private struct ResultCard: View {
  let dictation: Dictation
  let edit: () -> Void

  @Environment(PhoneSession.self) private var session

  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: Spaces.Space.l) {
        HStack(spacing: Spaces.Space.xs) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Spaces.Color.success)
            .accessibilityHidden(true)
          // iOS clears the copy after `Clipboard.lifetime`; the text itself stays here.
          Text("Copied. Paste it in the next 10 minutes.")
        }
        .spacesText(.caption)

        Text(dictation.text)
          .spacesText(.body)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)

        // Side by side when they fit, stacked when the text is set very large.
        ViewThatFits(in: .horizontal) {
          HStack(spacing: Spaces.Space.s) { actions }
          VStack(alignment: .leading, spacing: Spaces.Space.s) { actions }
        }
        .buttonStyle(.spaces(.tertiary, size: .small))
      }
    }
  }

  @ViewBuilder private var actions: some View {
    Button {
      session.dictation.copy(dictation)
    } label: {
      Label("Copy", systemImage: "doc.on.doc")
    }
    ShareLink(item: dictation.text) {
      Label("Share", systemImage: "square.and.arrow.up")
    }
    Button(action: edit) {
      Label("Edit", systemImage: "pencil")
    }
  }
}

/// Says why there is no text, and offers the way out.
private struct ProblemBanner: View {
  let problem: PhoneDictation.Problem

  @Environment(PhoneSession.self) private var session

  var body: some View {
    let dictation = session.dictation
    switch problem {
    case .missingKey:
      Banner(
        .warning,
        title: "Add your OpenAI key",
        message:
          "Spaces uses your own OpenAI key to turn speech into text. The key stays on this iPhone."
      ) {
        Button("Open Settings") { session.tab = .settings }
          .buttonStyle(.spaces(.tertiary, size: .small))
      }
    case .microphoneDenied:
      Banner(
        .warning,
        title: "The microphone is turned off",
        message: "Allow the microphone for Spaces in the Settings app, then come back."
      ) {
        Button("Open the Settings app") {
          Task { await dictation.fixMicrophone() }
        }
        .buttonStyle(.spaces(.tertiary, size: .small))
      }
    case .nothingHeard:
      Banner(.info, title: "Nothing was heard", message: "Tap the button, speak, then tap it again.") {
        Button("OK") { dictation.dismissProblem() }
          .buttonStyle(.spaces(.tertiary, size: .small))
      }
    case .failed(let message, let retry):
      Banner(.error, title: "That did not work", message: message) {
        HStack(spacing: Spaces.Space.s) {
          if retry != nil {
            Button("Try again") {
              Task { await dictation.retry() }
            }
          }
          Button("Dismiss") { dictation.dismissProblem() }
        }
        .buttonStyle(.spaces(.tertiary, size: .small))
      }
    }
  }
}

/// The record button and what goes with it, pinned to the bottom where a thumb reaches.
private struct RecordDock: View {
  @Environment(PhoneSession.self) private var session
  /// True from the moment a long press is recognised until the finger comes up.
  @GestureState private var isHolding = false

  var body: some View {
    let dictation = session.dictation
    VStack(spacing: Spaces.Space.xs) {
      status
        .frame(minHeight: Self.statusHeight)
      RecordButton(mode, diameter: Self.buttonDiameter) {
        Task { await dictation.toggle() }
      }
      .simultaneousGesture(hold)
      // Still tappable when something is in the way: the banner above says what to do.
      .opacity(blocker == nil ? 1 : 0.4)
      .accessibilityHint("Double tap to start or finish. Touch and hold to talk while you hold.")
      // Beside the button, so the dock is no taller while recording than at rest.
      .overlay(alignment: .leading) {
        Button("Cancel") { dictation.cancel() }
          .buttonStyle(.spaces(.ghost, size: .small))
          .fixedSize()
          .opacity(dictation.phase.isBusy ? 1 : 0)
          .disabled(!dictation.phase.isBusy)
          .accessibilityHidden(!dictation.phase.isBusy)
          .alignmentGuide(.leading) { size in size[.trailing] + Spaces.Space.l }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, Spaces.Space.xl)
    .padding(.bottom, Spaces.Space.xs)
    .background { fade }
    .animation(Spaces.Motion.smooth, value: dictation.phase.isBusy)
    .onChange(of: isHolding) { _, holding in
      if holding {
        dictation.holdBegan()
      } else {
        Task { await dictation.holdEnded() }
      }
    }
  }

  private static let statusHeight: CGFloat = 32
  private static let buttonDiameter: CGFloat = 96

  private var mode: RecordButton.Mode {
    switch session.dictation.phase {
    case .recording: .recording(level: session.dictation.level)
    case .processing: .processing
    case .idle, .failed: .idle
    }
  }

  /// A press that stays down: talk while holding, finish on release. The button's own tap
  /// still works for tap-to-start and tap-to-finish.
  private var hold: some Gesture {
    LongPressGesture(minimumDuration: 0.25)
      .sequenced(before: DragGesture(minimumDistance: 0))
      .updating($isHolding) { value, holding, _ in
        if case .second(true, _) = value { holding = true }
      }
  }

  @ViewBuilder private var status: some View {
    switch session.dictation.phase {
    case .recording(_, let since, let handsFree):
      // With very large text the hint goes first, then the bars: the clock always stays.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: Spaces.Space.m) {
          clock(since)
          bars
          Text(handsFree ? "Tap to finish" : "Let go to finish")
            .spacesText(.caption)
            .lineLimit(1)
        }
        HStack(spacing: Spaces.Space.m) {
          clock(since)
          bars
        }
        clock(since)
      }
    case .processing:
      HStack(spacing: Spaces.Space.s) {
        ProcessingIndicator(tint: Spaces.Color.textSecondary, height: 18)
        Text("Writing your text")
          .spacesText(.caption)
      }
    case .idle, .failed:
      Text(blocker ?? "Tap to speak, or hold to talk")
        .spacesText(.caption)
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spaces.Space.l)
    }
  }

  private func clock(_ since: Date) -> some View {
    Text(since, style: .timer)
      .spacesText(.bodyStrong)
      .monospacedDigit()
      .lineLimit(1)
      .accessibilityLabel("Recording")
  }

  private var bars: some View {
    Waveform(level: session.dictation.level, bars: 15, tint: Spaces.Color.accent, height: 24)
  }

  /// What must be fixed before the button can record, in a few words.
  private var blocker: String? {
    switch session.dictation.problem {
    case .missingKey: "Add your OpenAI key first"
    case .microphoneDenied: "Turn on the microphone first"
    case .nothingHeard, .failed, nil: nil
    }
  }

  /// The page fades out behind the dock instead of being cut off by a line.
  private var fade: some View {
    VStack(spacing: 0) {
      LinearGradient(
        colors: [Spaces.Color.panel.opacity(0), Spaces.Color.panel],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: Spaces.Space.xl)
      Spaces.Color.panel
    }
    .ignoresSafeArea(edges: .bottom)
  }
}

extension DictationEngine.Phase {
  /// Recording, or making the text: the two states a person can cancel.
  fileprivate var isBusy: Bool {
    switch self {
    case .recording, .processing: true
    case .idle, .failed: false
    }
  }
}
