import SwiftUI
import WisperDomain
import WisperEngine

// MARK: - General

struct GeneralSettings: View {
  @Environment(AppModel.self) private var model
  @Environment(\.wisperIdiom) private var idiom
  @State private var devices: [AudioDevice] = []

  var body: some View {
    PageSection("You") {
      Card(padding: 0) {
        SettingsItem(
          "Your name",
          description: "Used to greet you, and so your name is spelled right."
        ) {
          DraftField(
            placeholder: "Your name",
            value: model.settings.userName,
            check: NameDraft.check
          ) { name in
            model.update { $0.userName = name }
          }
        }
      }
    }
    PageSection("Dictation") {
      Card(padding: 0) {
        SettingsItem(
          "Spoken language",
          description: "Pick yours for more accurate text."
        ) {
          Dropdown(
            "Spoken language",
            selection: model.settingBinding(\.language),
            options: LanguageOptions.codes,
            title: LanguageOptions.title
          )
        }
        SettingsDivider()
        ToggleRow(
          "Smart formatting",
          description: FormattingCopy.description(isOn: model.settings.smartFormatting),
          isOn: model.settingBinding(\.smartFormatting)
        )
        SettingsDivider()
        SettingsItem(
          "Microphone",
          description: MicrophoneOptions.summary(devices: devices, selected: model.settings.microphoneID)
        ) {
          Dropdown(
            "Microphone",
            selection: model.settingBinding(\.microphoneID),
            options: MicrophoneOptions.ids(devices: devices, selected: model.settings.microphoneID)
          ) { id in
            MicrophoneOptions.title(id, devices: devices)
          }
        }
      }
    }
    PageSection("App") {
      Card(padding: 0) {
        ToggleRow(
          "Play sounds",
          description: "A soft sound when dictation starts and stops.",
          isOn: model.settingBinding(\.playSounds)
        )
        if idiom == .mac {
          SettingsDivider()
          ToggleRow(
            "Show the floating pill",
            description: "A small bar at the bottom of the screen that shows when Open Wisper is listening.",
            isOn: model.settingBinding(\.showPill)
          )
          SettingsDivider()
          ToggleRow("Open at login", isOn: model.settingBinding(\.launchAtLogin))
        }
      }
    }
    .task {
      // Microphones come and go (headsets, phones), so keep the list fresh while it is shown.
      while !Task.isCancelled {
        let found = await model.capture.microphones()
        if found != devices { devices = found }
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }
}

enum FormattingCopy {
  static func description(isOn: Bool) -> String {
    isOn
      ? "Removes filler words and fixes punctuation, using the text model."
      : "Off: your text is typed exactly as it was heard."
  }
}

enum NameDraft {
  static func check(_ text: String) -> DraftField.Check {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? .reject("Your name cannot be empty.") : .save(trimmed)
  }
}

// MARK: - Meetings

struct MeetingSettingsSection: View {
  let open: (SettingsSection) -> Void

  @Environment(AppModel.self) private var model
  @Environment(\.wisperIdiom) private var idiom
  @State private var computerAudioIsBlocked = false

  var body: some View {
    PageSection("Recording") {
      Card(padding: 0) {
        if idiom == .mac {
          ToggleRow(
            "Record computer audio",
            description:
              "Captures the other side of your calls, not only your microphone. "
              + "Needs the System audio recording permission.",
            isOn: model.settingBinding(\.meetings.captureSystemAudio)
          )
          SettingsDivider()
        }
        ToggleRow(
          "Keep audio after transcribing",
          description: "Off: the recording is deleted once its text is ready.",
          isOn: model.settingBinding(\.meetings.keepAudio)
        )
      }
    }
    PageSection("Notes") {
      Card(padding: 0) {
        ToggleRow(
          "Write notes automatically",
          description: "When a recording ends, write a summary, decisions and action items.",
          isOn: model.settingBinding(\.meetings.autoSummarize)
        )
      }
    }
    if idiom == .mac, model.settings.meetings.captureSystemAudio, computerAudioIsBlocked {
      Banner(
        .warning,
        title: "Computer audio is not allowed yet",
        message: "Until you allow it, meetings record only your own voice."
      ) {
        Button("Permissions") { open(.permissions) }
          .buttonStyle(.wisper(.tertiary, size: .small))
      }
    }
    SetupParagraph("Tell people before you record them.", style: .caption)
      .task {
        // The permission can change in System Settings while this section is open.
        while !Task.isCancelled {
          let permissions = model.permissions
          let blocked =
            permissions.needed.contains(.systemAudio) && permissions.status(.systemAudio) != .granted
          if blocked != computerAudioIsBlocked { computerAudioIsBlocked = blocked }
          try? await Task.sleep(for: .seconds(1))
        }
      }
  }
}

// MARK: - OpenAI

struct OpenAISettings: View {
  @Binding var dialog: SettingsDialog?

  @Environment(AppModel.self) private var model
  @Environment(\.wisperIdiom) private var idiom
  @State private var typingTranscriptionModel = false
  @State private var typingTextModel = false

  var body: some View {
    PageSection("Your key") {
      Card(padding: 0) {
        HStack(alignment: .center, spacing: Wisper.Space.l) {
          VStack(alignment: .leading, spacing: Wisper.Space.xs) {
            HStack(spacing: Wisper.Space.s) {
              Text("OpenAI API key").wisperText(.bodyStrong)
              Badge(
                model.hasAPIKey ? "Connected" : "Not connected",
                tone: model.hasAPIKey ? .success : .warning
              )
            }
            Text(
              OpenAICopy.keyStatus(hasKey: model.hasAPIKey, customServer: model.settings.apiBaseURL != nil)
            )
            .wisperText(.caption)
            .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, SetupMetrics.rowInset)
        .padding(.top, Wisper.Space.l)
        HStack(spacing: Wisper.Space.s) {
          Button(model.hasAPIKey ? "Change key" : "Add key") { dialog = .apiKey }
            .buttonStyle(.wisper(model.hasAPIKey ? .secondary : .primary, size: .small))
          if model.hasAPIKey {
            Button("Remove key") { dialog = .removeKey }
              .buttonStyle(.wisper(.ghost, size: .small))
          }
          Spacer(minLength: Wisper.Space.s)
          if idiom == .mac { SetupLink("Get a key", url: SetupLinks.openAIKeys) }
        }
        .padding(.horizontal, SetupMetrics.rowInset)
        .padding(.top, Wisper.Space.m)
        .padding(.bottom, Wisper.Space.l)
      }
      SetupParagraph(
        "You pay OpenAI directly for what you use. Open Wisper adds nothing on top.",
        style: .caption
      )
      if idiom == .phone { SetupLink("Get a key", url: SetupLinks.openAIKeys) }
    }
    PageSection("Models") {
      Card(padding: 0) {
        ModelPicker(
          title: "Transcription model",
          description: "Turns your voice into text.",
          suggested: WisperDomain.Settings.suggestedTranscriptionModels,
          current: model.settings.transcriptionModel,
          isTyping: $typingTranscriptionModel
        ) { name in
          model.update { $0.transcriptionModel = name }
        }
        SettingsDivider()
        ModelPicker(
          title: "Text model",
          description: "Cleans up dictations, follows spoken commands and writes meeting notes.",
          suggested: WisperDomain.Settings.suggestedTextModels,
          current: model.settings.textModel,
          isTyping: $typingTextModel
        ) { name in
          model.update { $0.textModel = name }
        }
      }
    }
    PageSection("Server") {
      Card(padding: 0) {
        SettingsItem(
          "Custom server address",
          description:
            "For a proxy or a model server on your own machine that works like OpenAI. "
            + "Leave empty to use OpenAI.",
          layout: .stacked
        ) {
          DraftField(
            placeholder: "Server address, such as http://localhost:11434/v1",
            value: model.settings.apiBaseURL ?? "",
            isCode: true,
            fillsWidth: true,
            check: ServerDraft.check
          ) { address in
            model.update { $0.apiBaseURL = address.isEmpty ? nil : address }
          }
        }
      }
    }
  }
}

enum OpenAICopy {
  static func keyStatus(hasKey: Bool, customServer: Bool) -> String {
    switch (hasKey, customServer) {
    case (true, false): "Kept in the Keychain on this device. It is sent only to OpenAI."
    case (true, true): "Kept in the Keychain on this device. It is sent only to your custom server."
    case (false, false): "Add your key to start dictating. It is kept in the Keychain on this device."
    case (false, true): "No key saved. That is fine if your custom server does not need one."
    }
  }
}

enum ServerDraft {
  static func check(_ text: String) -> DraftField.Check {
    let address = ServerAddress(text)
    return address.isValid ? .save(address.address ?? "") : .reject(ServerAddress.invalidMessage)
  }
}

/// A select box of suggested models, with "Custom…" opening a field for any other name.
private struct ModelPicker: View {
  let title: String
  let description: String
  let suggested: [String]
  let current: String
  @Binding var isTyping: Bool
  let save: (String) -> Void

  var body: some View {
    let choice = ModelChoice.selection(current: current, suggested: suggested, typing: isTyping)
    SettingsItem(title, description: description) {
      Dropdown(
        title,
        selection: Binding(
          get: { choice },
          set: { picked in
            switch picked {
            case .named(let name):
              isTyping = false
              save(name)
            case .custom:
              isTyping = true
            }
          }
        ),
        options: ModelChoice.options(suggested: suggested),
        title: \.title
      )
    }
    if choice == .custom {
      DraftField(
        placeholder: "\(title) name",
        value: current,
        isCode: true,
        fillsWidth: true,
        check: { text in
          ModelChoice.typedName(text).map(DraftField.Check.save) ?? .reject("Type a model name.")
        },
        save: save
      )
      .padding(.horizontal, SetupMetrics.rowInset)
      .padding(.bottom, Wisper.Space.l)
    }
  }
}

// MARK: - Agents

struct AgentSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    SetupParagraph(
      "AI agents such as Claude Code, Cursor or any tool that speaks MCP can read and update your "
        + "meeting notes through wisper, a small program that comes with Open Wisper. "
        + "It works only with the files on this device."
    )
    if let path = model.host.agentToolPath {
      PageSection("Claude Code") {
        VStack(alignment: .leading, spacing: Wisper.Space.s) {
          CopyBlock("Claude Code command", text: AgentSetup.claudeCommand(toolPath: path))
          SetupParagraph("Run this once in a terminal.", style: .caption)
        }
      }
      PageSection("Cursor, Claude Desktop and other tools") {
        VStack(alignment: .leading, spacing: Wisper.Space.s) {
          CopyBlock("Settings for other tools", text: AgentSetup.jsonConfig(toolPath: path))
          SetupParagraph("Paste this into the MCP settings of your tool.", style: .caption)
        }
      }
      PageSection("Where the program is") {
        CopyBlock("Path of the wisper program", text: path)
      }
    } else {
      Banner(
        .info,
        title: "This is a Mac feature",
        message: "The wisper program comes with Open Wisper for Mac. Set up your agents there."
      )
    }
    PageSection("What agents can do") {
      Card {
        VStack(alignment: .leading, spacing: Wisper.Space.l) {
          SetupFact(
            "doc.text.magnifyingglass",
            title: "Read and search",
            detail: "Meetings, transcripts, action items and your dictation history."
          )
          SetupFact(
            "square.and.pencil",
            title: "Update",
            detail: "Add notes and action items, tick them off, change titles and tags, export a meeting."
          )
          SetupFact(
            "record.circle",
            title: "Record",
            detail: "Start and stop a meeting recording, and add words and snippets."
          )
          SetupFact(
            "lock",
            title: "Never your key",
            detail: "wisper cannot read your OpenAI key and makes no network calls."
          )
        }
      }
      SetupLink("Read the guide", url: SetupLinks.agentsGuide)
    }
  }
}

// MARK: - Privacy

struct PrivacySettings: View {
  @Binding var dialog: SettingsDialog?

  @Environment(AppModel.self) private var model
  @Environment(\.wisperIdiom) private var idiom

  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: Wisper.Space.l) {
        SetupFact(
          "internaldrive",
          title: "Everything is stored on this device",
          detail: "Your dictations, meetings, notes and settings are plain files you can read."
        )
        SetupFact(
          "waveform",
          title: PrivacyCopy.destinationTitle(customServer: model.settings.apiBaseURL != nil),
          detail: "Audio and text are sent there with your own key, and nowhere else."
        )
        SetupFact(
          "eye.slash",
          title: "No account, no tracking",
          detail: "Open Wisper has no sign-up, no analytics and no server of its own."
        )
      }
    }
    PageSection("Dictation history") {
      Card(padding: 0) {
        SettingsItem(
          "Keep history for",
          description: PrivacyCopy.retention(model.settings.historyRetention)
        ) {
          Dropdown(
            "Keep history for",
            selection: model.settingBinding(\.historyRetention),
            options: HistoryRetention.allCases,
            title: \.label
          )
        }
        SettingsDivider()
        ToggleRow(
          "Keep audio of dictations",
          description: "Lets you try again when a dictation fails. Deleted together with its history entry.",
          isOn: model.settingBinding(\.keepDictationAudio)
        )
        SettingsDivider()
        SettingRow(
          "Delete all dictation history",
          description: PrivacyCopy.historyCount(model.dictations.count)
        ) {
          Button("Delete…") { dialog = .deleteHistory }
            .buttonStyle(.wisper(.secondary, size: .small))
            .disabled(model.dictations.isEmpty)
            .accessibilityLabel("Delete all dictation history")
        }
      }
    }
    if idiom == .mac, let folder = model.host.dataFolder {
      PageSection("Your files") {
        Card(padding: 0) {
          SettingRow("Data folder", description: PrivacyCopy.shortPath(folder)) {
            Button("Show data folder") { model.host.reveal(folder) }
              .buttonStyle(.wisper(.secondary, size: .small))
          }
        }
      }
    }
  }
}

enum PrivacyCopy {
  static func destinationTitle(customServer: Bool) -> String {
    customServer ? "Your voice goes only to your custom server" : "Your voice goes only to OpenAI"
  }

  static func retention(_ retention: HistoryRetention) -> String {
    switch retention {
    case .forever: "Dictations stay until you delete them."
    case .never: "Dictations are not saved at all."
    case .month, .week, .day: "Older dictations are deleted by themselves."
    }
  }

  static func historyCount(_ count: Int) -> String {
    switch count {
    case 0: "There is nothing in your history."
    case 1: "1 dictation, with its audio."
    default: "\(count.formatted()) dictations, with their audio."
    }
  }

  static func deleteWarning(count: Int) -> String {
    let what = count == 1 ? "1 dictation and its audio" : "\(count.formatted()) dictations and their audio"
    return "This deletes \(what) from this device. It cannot be undone. Meetings are not touched."
  }

  /// A folder path with the home folder written as `~`.
  static func shortPath(_ folder: URL, home: String = NSHomeDirectory()) -> String {
    let path = folder.path
    guard path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
  }
}

// MARK: - Permissions

struct PermissionSettings: View {
  var body: some View {
    SetupParagraph(
      "Open Wisper asks your system for a few things. You can leave any of them off; "
        + "each one says what stops working without it."
    )
    PermissionsList()
  }
}

// MARK: - About

struct AboutSettings: View {
  var body: some View {
    Card {
      VStack(alignment: .leading, spacing: Wisper.Space.l) {
        Wordmark(size: 24)
        VStack(alignment: .leading, spacing: Wisper.Space.xs) {
          Text("Version \(AppVersion.text())").wisperText(.bodyStrong)
          Text("Voice dictation and meeting notes that stay on your device.")
            .wisperText(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    PageSection("Open source") {
      Card(padding: 0) {
        SettingRow(
          "Open source under the MIT licence",
          description: "Read the code, change it, share it."
        ) {
          SetupLink("GitHub", url: SetupLinks.repository)
        }
      }
      SetupParagraph(
        "Open Wisper is an independent project. It is not made by, or connected to, OpenAI or any other "
          + "dictation app.",
        style: .caption
      )
    }
  }
}
