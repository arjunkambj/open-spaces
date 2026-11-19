import SwiftUI
import WisperDomain
import WisperEngine
import WisperMac
import WisperUI

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
  private let showsGlobeHint: Bool?
  private let previewRecording: ShortcutAction?
  private let previewProblem: (ShortcutAction, String)?

  public init() {
    self.init(showsGlobeHint: nil)
  }

  /// For still pictures: fixes what the system would decide and what the person would be doing.
  init(
    showsGlobeHint: Bool?,
    recording: ShortcutAction? = nil,
    problem: (ShortcutAction, String)? = nil
  ) {
    self.showsGlobeHint = showsGlobeHint
    previewRecording = recording
    previewProblem = problem
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Wisper.Space.l) {
      if needsGlobeHint {
        Banner(
          .warning,
          title: "macOS also reacts to the fn key",
          message: "In Keyboard settings, set “Press 🌐 key to” to “Do Nothing”. "
            + "Otherwise the emoji picker can open when you dictate."
        ) {
          Button("Open Keyboard settings") { GlobeKey.openSettings() }
            .buttonStyle(.wisper(.tertiary, size: .small))
        }
      }
      Card(padding: 0) {
        ForEach(ShortcutAction.allCases, id: \.self) { action in
          if action != ShortcutAction.allCases.first {
            Hairline().padding(.horizontal, Wisper.Space.l + Wisper.Space.xs)
          }
          row(for: action)
        }
      }
      HStack {
        Text("Press Esc at any time to cancel a dictation.")
          .wisperText(.caption)
        Spacer()
        Button("Reset to defaults") { reset() }
          .buttonStyle(.wisper(.secondary, size: .small))
          .disabled(model.settings.shortcuts == WisperDomain.Settings.defaultShortcuts)
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
          .wisperText(.caption, color: Wisper.Color.danger)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, Wisper.Space.l + Wisper.Space.xs)
          .padding(.bottom, Wisper.Space.l)
      }
    }
  }

  private func restingControl(for action: ShortcutAction) -> some View {
    let combo = model.settings.shortcut(for: action) ?? KeyCombo()
    return HStack(spacing: Wisper.Space.s) {
      if combo.isEmpty {
        Text("Not set").wisperText(.caption, color: Wisper.Color.textTertiary)
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
    return HStack(spacing: Wisper.Space.s) {
      if held.isEmpty {
        Text("Press the new shortcut…").wisperText(.captionStrong, color: Wisper.Color.accent)
      } else {
        KeyCapRow(held.keyCaps)
      }
      Button("Cancel") { recorder?.cancel() }
        .buttonStyle(.wisper(.ghost, size: .small))
    }
    .accessibilityElement(children: .contain)
  }

  private var needsGlobeHint: Bool {
    let usesGlobeAlone = model.settings.shortcuts.values.contains { $0 == KeyCombo(modifiers: [.function]) }
    return usesGlobeAlone && (showsGlobeHint ?? GlobeKey.interferes)
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
    model.update { $0.shortcuts = WisperDomain.Settings.defaultShortcuts }
  }
}
