import SpacesDomain
import SpacesEngine
import SpacesMac
import SpacesUI
import SwiftUI

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
  private let globeHint: GlobeKeyHint.Stage?

  /// One thing that stops dictation from working.
  enum Missing: Hashable {
    case key
    case permission(Permission)
    /// The global shortcuts are not running at all (the demo).
    case shortcuts
  }

  public init() {
    self.init(globeHint: nil)
  }

  /// - globeHint: for still pictures, what the fn-key hint says; `nil` follows the Mac.
  init(globeHint: GlobeKeyHint.Stage?) {
    self.globeHint = globeHint
  }

  public var body: some View {
    // Laid out like the other setup steps: centred, a headline, a line of help, then the thing to do.
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: Spaces.Space.xl) {
          VStack(spacing: Spaces.Space.l) {
            Text("Now try it")
              .spacesText(.hero)
              .multilineTextAlignment(.center)
              .accessibilityAddTraits(.isHeader)
            instruction
          }
          VStack(alignment: .leading, spacing: Spaces.Space.m) {
            ForEach(missing, id: \.self) { item in banner(for: item) }
            GlobeKeyHint(preview: globeHint)
            SpacesTextEditor(text: $text, placeholder: "What you say will be typed here.", height: 96)
              .focused($boxHasCursor)
            status
          }
          .frame(maxWidth: Self.width)
        }
        .padding(.horizontal, Spaces.Space.xxl)
        .padding(.vertical, Spaces.Space.m)
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
      HStack(spacing: Spaces.Space.s) {
        Text("Hold").spacesText(.body, color: Spaces.Color.textSecondary)
        KeyCapRow(combo.keyCaps).accessibilityLabel(combo.spokenName)
        Text("and speak. Let go when you are done.").spacesText(.body, color: Spaces.Color.textSecondary)
      }
    } else {
      Text("Push to talk has no shortcut yet. You can set one in Settings later.")
        .spacesText(.body, color: Spaces.Color.textSecondary)
        .multilineTextAlignment(.center)
    }
  }

  /// One line that follows what the engine is doing.
  private var status: some View {
    HStack(spacing: Spaces.Space.s) {
      switch model.dictation.phase {
      case .recording:
        Waveform(level: Double(model.dictation.level), tint: Spaces.Color.accent, height: 16)
        Text("Listening…").spacesText(.captionStrong, color: Spaces.Color.accent)
      case .processing:
        ProcessingIndicator(height: 16)
        Text("Writing it out…").spacesText(.caption)
      case .failed(let message):
        Image(systemName: "exclamationmark.circle.fill")
          .spacesText(.caption, color: Spaces.Color.danger)
          .accessibilityHidden(true)
        Text(message).spacesText(.caption, color: Spaces.Color.danger)
      case .idle:
        if text.isEmpty {
          Text("Nothing yet. You can also carry on and try it later.").spacesText(.caption)
        } else {
          Image(systemName: "checkmark.circle.fill")
            .spacesText(.caption, color: Spaces.Color.success)
            .accessibilityHidden(true)
          Text("That is all there is to it. It works the same in every app.").spacesText(.caption)
        }
      }
    }
    .frame(minHeight: 20, alignment: .leading)
    .animation(Spaces.Motion.quick, value: model.dictation.phase)
  }

  private func banner(for item: Missing) -> some View {
    switch item {
    case .key:
      Banner(
        .warning,
        title: "No OpenAI key yet",
        message: "Go back to add your key. Nothing can be turned into text without it."
      ) { EmptyView().spacesFix }
    case .shortcuts:
      Banner(
        title: "Shortcuts are off in the demo",
        message: "Use the button to see what dictating looks like."
      ) {
        Button(model.dictation.isRecording ? "Stop" : "Pretend to dictate") { controls.toggleHandsFree() }
          .buttonStyle(.spaces(.tertiary, size: .small))
          .spacesFix
      }
    case .permission(let permission):
      Banner(.warning, title: "\(permission.label) access is off", message: Self.reason(for: permission)) {
        Button("Turn on") { controls.requestPermission(permission) }
          .buttonStyle(.spaces(.tertiary, size: .small))
          .spacesFix
      }
    }
  }

  private static func reason(for permission: Permission) -> String {
    switch permission {
    case .microphone: "Spaces cannot hear you without it."
    case .accessibility: "Spaces needs it to notice the key and to type the text for you."
    case .systemAudio: "It is only needed to record the other side of a call."
    }
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
  fileprivate var spacesFix: AnyView { AnyView(self) }
}
