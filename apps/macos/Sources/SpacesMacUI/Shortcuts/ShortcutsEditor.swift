import SpacesDomain
import SpacesEngine
import SpacesMac
import SpacesUI
import SwiftUI

/// The list of global shortcuts, each with a way to record a new one.
///
/// Goes into the Settings screen. Reads `AppModel` and `MacControls` from the
/// environment and saves every change at once.
public struct ShortcutsEditor: View {
  @Environment(AppModel.self) private var model
  @Environment(MacControls.self) private var controls
  @State private var recorder: ShortcutRecorder?
  /// The action whose new shortcut is being recorded.
  @State private var recording: ShortcutAction?
  /// Why the last recorded keys were turned down, per action.
  @State private var problems: [ShortcutAction: String] = [:]
  private let globeHint: GlobeKeyHint.Stage?
  private let globeUndo: GlobeKey.SystemUse?
  private let previewRecording: ShortcutAction?
  private let previewProblem: (ShortcutAction, String)?

  public init() {
    self.init(globeHint: nil)
  }

  /// For still pictures: fixes what the system would decide and what the person would be doing.
  /// - globeHint: what the fn-key hint says; `nil` follows the Mac.
  /// - globeUndo: the fn-key choice Spaces replaced, to show the line that says so.
  init(
    globeHint: GlobeKeyHint.Stage?,
    globeUndo: GlobeKey.SystemUse? = nil,
    recording: ShortcutAction? = nil,
    problem: (ShortcutAction, String)? = nil
  ) {
    self.globeHint = globeHint
    self.globeUndo = globeUndo
    previewRecording = recording
    previewProblem = problem
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Spaces.Space.l) {
      GlobeKeyHint(preview: globeHint)
      Card(padding: 0) {
        ForEach(ShortcutAction.allCases, id: \.self) { action in
          if action != ShortcutAction.allCases.first {
            Hairline().padding(.horizontal, Spaces.Space.l + Spaces.Space.xs)
          }
          row(for: action)
        }
      }
      HStack {
        Text("Press Esc at any time to cancel a dictation.")
          .spacesText(.caption)
        Spacer()
        Button("Reset to defaults") { reset() }
          .buttonStyle(.spaces(.secondary, size: .small))
          .disabled(model.settings.shortcuts == SpacesDomain.Settings.defaultShortcuts)
      }
      // Only when the hint is not being staged for a picture of something else.
      if globeHint == nil || globeUndo != nil {
        GlobeKeyUndoNote(preview: globeUndo)
      }
    }
    .onAppear {
      if recorder == nil { recorder = ShortcutRecorder(suspending: controls.monitor) }
    }
    .onDisappear { recorder?.cancel() }
  }

  private func row(for action: ShortcutAction) -> some View {
    let isRecording = (previewRecording ?? recording) == action
    let problem = previewProblem.flatMap { $0.0 == action ? $0.1 : nil } ?? problems[action]
    return VStack(alignment: .leading, spacing: 0) {
      SettingRow(action.label, description: action.help) {
        if isRecording {
          recordingControl
        } else {
          restingControl(for: action)
        }
      }
      if let problem, !isRecording {
        Label(problem, systemImage: "exclamationmark.circle.fill")
          .spacesText(.caption, color: Spaces.Color.danger)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, Spaces.Space.l + Spaces.Space.xs)
          .padding(.bottom, Spaces.Space.l)
      }
    }
  }

  private func restingControl(for action: ShortcutAction) -> some View {
    let combo = model.settings.shortcut(for: action) ?? KeyCombo()
    return HStack(spacing: Spaces.Space.s) {
      if combo.isEmpty {
        Text("Not set").spacesText(.caption, color: Spaces.Color.textTertiary)
      } else {
        KeyCapRow(combo.keyCaps)
          .accessibilityLabel(combo.spokenName)
      }
      IconButton("pencil", label: "Change the shortcut for \(action.label)", size: .small) { record(action) }
      IconButton("xmark", label: "Remove the shortcut for \(action.label)", size: .small) { clear(action) }
        .disabled(combo.isEmpty)
        .opacity(combo.isEmpty ? 0.35 : 1)
    }
  }

  private var recordingControl: some View {
    let held = recorder?.held ?? KeyCombo()
    return HStack(spacing: Spaces.Space.s) {
      if held.isEmpty {
        Text("Press the new shortcut…").spacesText(.captionStrong, color: Spaces.Color.accent)
      } else {
        KeyCapRow(held.keyCaps)
      }
      Button("Cancel") { recorder?.cancel() }
        .buttonStyle(.spaces(.ghost, size: .small))
    }
    .accessibilityElement(children: .contain)
  }

  private func record(_ action: ShortcutAction) {
    guard let recorder else { return }
    problems[action] = nil
    recording = action
    Task {
      let combo = await recorder.record()
      // A newer recording may have taken over while this one was ending.
      if recording == action, !recorder.isRecording { recording = nil }
      guard let combo else { return }
      if let problem = combo.problem(for: action, in: model.settings.shortcuts) {
        problems[action] = problem.message
      } else {
        model.update { $0.shortcuts[action] = combo }
      }
    }
  }

  private func clear(_ action: ShortcutAction) {
    problems[action] = nil
    // An empty shortcut, not a missing one: a missing one would come back as the default.
    model.update { $0.shortcuts[action] = KeyCombo() }
  }

  private func reset() {
    recorder?.cancel()
    problems = [:]
    model.update { $0.shortcuts = SpacesDomain.Settings.defaultShortcuts }
  }
}
