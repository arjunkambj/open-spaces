import SpacesDomain
import SpacesEngine
import SwiftUI

/// A text field for one stored value. It keeps its own draft while someone types and saves
/// by itself: a moment after the typing stops, on Return, and when the field goes away.
/// A draft that fails `check` is never saved; its message shows under the field.
struct DraftField: View {
  enum Check: Equatable {
    /// Store this (tidied) text.
    case save(String)
    /// Do not store; show this message.
    case reject(String)
  }

  private let placeholder: String
  private let value: String
  private let isCode: Bool
  private let fillsWidth: Bool
  private let check: (String) -> Check
  private let save: (String) -> Void

  @State private var draft: String
  @State private var error: String?

  /// - placeholder: shown while the field is empty. It is also the field's VoiceOver name.
  /// - value: the stored value. A change from elsewhere replaces the draft.
  /// - isCode: the text is an address or a model name, so the keyboard must not "correct" it.
  /// - fillsWidth: takes all the width it is given. Otherwise it has a fixed width, for the
  ///   end of a row.
  init(
    placeholder: String,
    value: String,
    isCode: Bool = false,
    fillsWidth: Bool = false,
    check: @escaping (String) -> Check,
    save: @escaping (String) -> Void
  ) {
    self.placeholder = placeholder
    self.value = value
    self.isCode = isCode
    self.fillsWidth = fillsWidth
    self.check = check
    self.save = save
    _draft = State(initialValue: value)
  }

  var body: some View {
    SpacesTextField(text: $draft, placeholder: placeholder, error: error)
      .autocorrectionDisabled(isCode)
      .frame(width: fillsWidth ? nil : SetupMetrics.rowFieldWidth)
      .onSubmit(commit)
      .onChange(of: draft) { _, text in
        if case .save = check(text) { error = nil }
      }
      .onChange(of: value) { _, stored in
        // Changed somewhere else (another window, an agent): show the new value.
        if check(draft) != .save(stored) {
          draft = stored
          error = nil
        }
      }
      .task(id: draft) {
        try? await Task.sleep(for: .milliseconds(450))
        if !Task.isCancelled { commit() }
      }
      .onDisappear(perform: commit)
  }

  private func commit() {
    switch check(draft) {
    case .save(let text):
      error = nil
      if text != value { save(text) }
    case .reject(let message):
      // Nothing typed yet: do not complain about what was already there.
      error = draft == value ? nil : message
    }
  }
}

/// The dialog a new OpenAI key is pasted into. The key is checked before it is stored.
struct APIKeyDialog: View {
  private let onClose: () -> Void

  @Environment(AppModel.self) private var model
  @State private var key: String
  @State private var error: String?
  @State private var isChecking = false

  init(preview: SettingsPreview = SettingsPreview(), onClose: @escaping () -> Void) {
    self.onClose = onClose
    _key = State(initialValue: preview.keyDraft)
    _error = State(initialValue: preview.keyError)
  }

  var body: some View {
    // A key belongs to one server, so the dialog names the one it is for.
    let host = ServerAddress(model.settings.apiBaseURL ?? "").customHost
    DialogCard(
      title: OpenAICopy.keyDialogTitle(hasKey: model.hasAPIKey, customHost: host),
      subtitle: OpenAICopy.keyDialogSubtitle(customHost: host),
      onClose: onClose
    ) {
      APIKeyField(
        host == nil ? APIKeyField.openAILabel : APIKeyField.serverLabel,
        text: $key,
        error: error,
        focusOnAppear: true
      )
      .onSubmit(save)
      .disabled(isChecking)
      if host == nil { SetupLink("Get a key from OpenAI", url: SetupLinks.openAIKeys) }
    } footer: {
      Button("Cancel", action: onClose).buttonStyle(.spaces())
      Button(isChecking ? "Checking…" : "Save key", action: save)
        .buttonStyle(.spaces(.primary))
        .keyboardShortcut(.defaultAction)
        .disabled(isChecking || APIKeyEntry.isEmpty(key))
    }
    .onChange(of: key) { _, _ in error = nil }
  }

  private func save() {
    guard !isChecking, !APIKeyEntry.isEmpty(key) else { return }
    isChecking = true
    Task {
      do {
        try await model.saveAPIKey(key)
        onClose()
      } catch {
        self.error = APIKeyEntry.message(for: error)
      }
      isChecking = false
    }
  }
}

/// The dialog an Anthropic key is pasted into. The key is checked with Anthropic before it is stored.
struct ClaudeKeyDialog: View {
  let onClose: () -> Void

  @Environment(AppModel.self) private var model
  @State private var key = ""
  @State private var error: String?
  @State private var isChecking = false

  var body: some View {
    DialogCard(
      title: model.hasClaudeKey ? "Change your Anthropic key" : "Add your Anthropic key",
      subtitle: "The key is checked with Anthropic first, then saved on this device only.",
      onClose: onClose
    ) {
      APIKeyField(ClaudeKeyField.label, text: $key, error: error, focusOnAppear: true)
        .onSubmit(save)
        .disabled(isChecking)
      SetupLink("Get a key from Anthropic", url: SetupLinks.anthropicKeys)
    } footer: {
      Button("Cancel", action: onClose).buttonStyle(.spaces())
      Button(isChecking ? "Checking…" : "Save key", action: save)
        .buttonStyle(.spaces(.primary))
        .keyboardShortcut(.defaultAction)
        .disabled(isChecking || APIKeyEntry.isEmpty(key))
    }
    .onChange(of: key) { _, _ in error = nil }
  }

  private func save() {
    guard !isChecking, !APIKeyEntry.isEmpty(key) else { return }
    isChecking = true
    Task {
      do {
        try await model.saveClaudeKey(key)
        onClose()
      } catch {
        self.error = APIKeyEntry.message(for: error)
      }
      isChecking = false
    }
  }
}

enum ClaudeKeyField {
  static let label = "Anthropic API key"
}

/// Small rules shared by every place a key is typed.
enum APIKeyEntry {
  static func isEmpty(_ key: String) -> Bool {
    key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// What to show under the field when a key could not be saved.
  static func message(for error: any Error) -> String {
    switch error {
    case SpacesError.missingAPIKey, SpacesError.anthropic(.missingAPIKey): "Paste your key first."
    case SpacesError.anthropic(.invalidAPIKey): "This key was not accepted. Check that you copied all of it."
    // The standard message points to Settings, which is where the person already is.
    case SpacesError.invalidAPIKey: "This key was not accepted. Check that you copied all of it."
    default: error.localizedDescription
    }
  }
}
