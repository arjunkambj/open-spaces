import SwiftUI
import WisperDomain
import WisperEngine
import WisperMac
import WisperUI

/// The last step of first-run setup: hold the key, speak, and watch the words
/// land in a text box. Says plainly what is missing when it cannot work yet.
///
/// Reads `AppModel` and `MacControls` from the environment. Turns the global
/// shortcuts on while it is showing, so the real thing is what gets tried.
public struct PracticeStep: View {
  @Environment(AppModel.self) private var model
  @Environment(MacControls.self) private var controls
  @State private var text = ""
  /// What is in the way, refreshed while the step is open.
  @State private var missing: [Missing] = []
  /// The text box has the cursor. Dictated text is typed where the cursor is.
  @FocusState private var boxHasCursor: Bool
  private let showsGlobeHint: Bool?

  /// One thing that stops dictation from working.
  enum Missing: Hashable {
    case key
    case permission(Permission)
    /// The global shortcuts are not running at all (the demo).
    case shortcuts
  }

  public init() {
    self.init(showsGlobeHint: nil)
  }

  init(showsGlobeHint: Bool?) {
    self.showsGlobeHint = showsGlobeHint
  }

  public var body: some View {
    // Laid out like the other setup steps: centred, a headline, a line of help, then the thing to do.
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: Wisper.Space.xl) {
          VStack(spacing: Wisper.Space.l) {
            Text("Now try it")
              .wisperText(.hero)
              .multilineTextAlignment(.center)
              .accessibilityAddTraits(.isHeader)
            instruction
          }
          VStack(alignment: .leading, spacing: Wisper.Space.m) {
            ForEach(missing, id: \.self) { item in banner(for: item) }
            if needsGlobeHint {
              Banner(
                title: "macOS also reacts to the fn key",
                message: "To stop the emoji picker opening, set “Press 🌐 key to” to “Do Nothing”."
              ) {
                Button("Open Keyboard settings") { GlobeKey.openSettings() }
                  .buttonStyle(.wisper(.tertiary, size: .small))
              }
            }
            WisperTextEditor(text: $text, placeholder: "What you say will be typed here.", height: 96)
              .focused($boxHasCursor)
            status
          }
          .frame(maxWidth: Self.width)
        }
        .padding(.horizontal, Wisper.Space.xxl)
        .padding(.vertical, Wisper.Space.m)
        .frame(maxWidth: .infinity)
        .frame(minHeight: proxy.size.height)
      }
    }
    .onChange(of: model.dictation.isRecording) { _, isRecording in
      // Keep the cursor in the box, so the words land here and not in another app.
      if isRecording { boxHasCursor = true }
    }
    .task {
      boxHasCursor = true
      controls.start()
      while !Task.isCancelled {
        let now = stillMissing()
        if now != missing { missing = now }
        try? await Task.sleep(for: .seconds(1))
      }
    }
    .onChange(of: model.dictation.last) { _, last in
      guard let last else { return }
      Task { await showResult(last.text) }
    }
  }

  /// The widest the text box and the notices get.
  private static let width: CGFloat = 560

  @ViewBuilder private var instruction: some View {
    if let combo = model.settings.shortcut(for: .pushToTalk), !combo.isEmpty {
      HStack(spacing: Wisper.Space.s) {
        Text("Hold").wisperText(.body, color: Wisper.Color.textSecondary)
        KeyCapRow(combo.keyCaps).accessibilityLabel(combo.spokenName)
        Text("and speak. Let go when you are done.").wisperText(.body, color: Wisper.Color.textSecondary)
      }
    } else {
      Text("Push to talk has no shortcut yet. You can set one in Settings later.")
        .wisperText(.body, color: Wisper.Color.textSecondary)
        .multilineTextAlignment(.center)
    }
  }

  /// One line that follows what the engine is doing.
  private var status: some View {
    HStack(spacing: Wisper.Space.s) {
      switch model.dictation.phase {
      case .recording:
        Waveform(level: Double(model.dictation.level), tint: Wisper.Color.accent, height: 16)
        Text("Listening…").wisperText(.captionStrong, color: Wisper.Color.accent)
      case .processing:
        ProcessingIndicator(height: 16)
        Text("Writing it out…").wisperText(.caption)
      case .failed(let message):
        Image(systemName: "exclamationmark.circle.fill")
          .wisperText(.caption, color: Wisper.Color.danger)
          .accessibilityHidden(true)
        Text(message).wisperText(.caption, color: Wisper.Color.danger)
      case .idle:
        if text.isEmpty {
          Text("Nothing yet. You can also carry on and try it later.").wisperText(.caption)
        } else {
          Image(systemName: "checkmark.circle.fill")
            .wisperText(.caption, color: Wisper.Color.success)
            .accessibilityHidden(true)
          Text("That is all there is to it. It works the same in every app.").wisperText(.caption)
        }
      }
    }
    .frame(minHeight: 20, alignment: .leading)
    .animation(Wisper.Motion.quick, value: model.dictation.phase)
  }

  private func banner(for item: Missing) -> some View {
    switch item {
    case .key:
      Banner(
        .warning,
        title: "No OpenAI key yet",
        message: "Go back to add your key. Nothing can be turned into text without it."
      ) { EmptyView().wisperFix }
    case .shortcuts:
      Banner(
        title: "Shortcuts are off in the demo",
        message: "Use the button to see what dictating looks like."
      ) {
        Button(model.dictation.isRecording ? "Stop" : "Pretend to dictate") { controls.toggleHandsFree() }
          .buttonStyle(.wisper(.tertiary, size: .small))
          .wisperFix
      }
    case .permission(let permission):
      Banner(.warning, title: "\(permission.label) access is off", message: Self.reason(for: permission)) {
        Button("Turn on") { controls.requestPermission(permission) }
          .buttonStyle(.wisper(.tertiary, size: .small))
          .wisperFix
      }
    }
  }

  private static func reason(for permission: Permission) -> String {
    switch permission {
    case .microphone: "Open Wisper cannot hear you without it."
    case .accessibility: "Open Wisper needs it to notice the key and to type the text for you."
    case .systemAudio: "It is only needed to record the other side of a call."
    }
  }

  private var needsGlobeHint: Bool {
    guard model.settings.shortcut(for: .pushToTalk) == KeyCombo(modifiers: [.function]) else { return false }
    if let showsGlobeHint { return showsGlobeHint }
    // Without the shortcuts (the demo) the fn key is never pressed for us.
    return controls.monitor != nil && GlobeKey.interferes
  }

  /// Checking never shows a system prompt, so it is safe to do once a second.
  private func stillMissing() -> [Missing] {
    var items: [Missing] = []
    let server = (model.settings.apiBaseURL ?? "").trimmingCharacters(in: .whitespaces)
    if !model.hasAPIKey, server.isEmpty { items.append(.key) }
    if controls.monitor == nil { items.append(.shortcuts) }
    for permission in [Permission.microphone, .accessibility]
    where model.permissions.needed.contains(permission) && model.permissions.status(permission) != .granted {
      items.append(.permission(permission))
    }
    return items
  }

  /// The words normally arrive by being typed into the box. When they did not
  /// (the box did not have the cursor), put them there, so the try still shows a result.
  private func showResult(_ words: String) async {
    try? await Task.sleep(for: .milliseconds(400))
    guard !words.isEmpty, !text.contains(words) else { return }
    text += text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? words : " " + words
  }
}

extension View {
  /// Erases the type of a banner's action, so banners with and without a button fit one return type.
  fileprivate var wisperFix: AnyView { AnyView(self) }
}
