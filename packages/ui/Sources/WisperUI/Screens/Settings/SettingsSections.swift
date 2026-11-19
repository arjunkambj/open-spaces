import SwiftUI
import WisperDomain
import WisperEngine

// MARK: - General

struct GeneralSettings: View {
  /// The platform's own row for how the app looks, when it has one.
  var appearance: AnyView?

  @Environment(AppModel.self) private var model
  @Environment(\.wisperIdiom) private var idiom
  @State private var devices: [AudioDevice] = []

  var body: some View {
    PageSection("Dictation") {
      Card(padding: 0) {
        SettingsItem("Your name", description: "So it is spelled right when you say it.") {
          DraftField(
            placeholder: "Your name",
            value: model.settings.userName,
            check: NameDraft.check
          ) { name in
            model.update { $0.userName = name }
          }
        }
        SettingsDivider()
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
            description: "A small bar at the bottom of the screen. It shows when Open Wisper is listening.",
            isOn: model.settingBinding(\.showPill)
          )
          SettingsDivider()
          ToggleRow("Open at login", isOn: model.settingBinding(\.launchAtLogin))
        }
        if let appearance {
          SettingsDivider()
          appearance
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
      ? "Takes out filler words and fixes punctuation."
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
              "Records the other side of a call too, not only your microphone.",
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
          description: "A summary, the decisions and the action items, when a recording ends.",
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
    // The stored address: the key state (`hasAPIKey`) is about the server it names.
    let server = ServerAddress(model.settings.apiBaseURL ?? "")
    PageSection("Your key") {
      Card(padding: 0) {
        HStack(alignment: .center, spacing: Wisper.Space.l) {
          VStack(alignment: .leading, spacing: Wisper.Space.xs) {
            HStack(spacing: Wisper.Space.s) {
              Text(server.customHost == nil ? APIKeyField.openAILabel : APIKeyField.serverLabel)
                .wisperText(.bodyStrong)
              // A server of the person's own may need no key, so having none is not a fault there.
              Badge(
                OpenAICopy.keyBadge(hasKey: model.hasAPIKey, customHost: server.customHost),
                tone: model.hasAPIKey ? .success : server.customHost == nil ? .warning : .neutral
              )
            }
            Text(OpenAICopy.keyStatus(hasKey: model.hasAPIKey, customHost: server.customHost))
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
          if idiom == .mac, server.customHost == nil { SetupLink("Get a key", url: SetupLinks.openAIKeys) }
        }
        .padding(.horizontal, SetupMetrics.rowInset)
        .padding(.top, Wisper.Space.m)
        .padding(.bottom, Wisper.Space.l)
      }
      // Said only while it is true: with a server of the person's own, nothing goes to OpenAI.
      if server.customHost == nil {
        SetupParagraph(
          "You pay OpenAI directly for what you use. Open Wisper adds nothing on top.",
          style: .caption
        )
        if idiom == .phone { SetupLink("Get a key", url: SetupLinks.openAIKeys) }
      }
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
          description: "Tidies dictations, follows spoken commands and writes meeting notes.",
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
            "For a server of your own that works like OpenAI. Leave empty to use OpenAI.",
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
      ServerNotice(address: server)
    }
  }
}

enum OpenAICopy {
  /// The line under "OpenAI API key": where the key is kept and where it goes.
  /// - customHost: the host of the custom server, or `nil` when requests go to OpenAI.
  static func keyStatus(hasKey: Bool, customHost: String?) -> String {
    switch (hasKey, customHost) {
    case (true, nil): "Kept in the Keychain on this device. It is sent only to OpenAI."
    case (true, let host?): "Kept in the Keychain on this device. It is sent to \(host), not to OpenAI."
    case (false, nil): "Add your key to start dictating. It is kept in the Keychain on this device."
    case (false, let host?):
      // Also what someone sees right after changing the address: the key they had is for
      // the other server and stays out of this one.
      "No key is saved for \(host). A key saved for another server is never sent to this one. "
        + "Add a key here if this server needs one."
    }
  }

  static func keyBadge(hasKey: Bool, customHost: String?) -> String {
    hasKey ? "Connected" : customHost == nil ? "Not connected" : "No key"
  }

  /// - customHost: the host of the custom server, or `nil` when requests go to OpenAI.
  static func keyDialogTitle(hasKey: Bool, customHost: String?) -> String {
    switch (hasKey, customHost) {
    case (true, nil): "Change your OpenAI key"
    case (false, nil): "Add your OpenAI key"
    case (true, let host?): "Change the key for \(host)"
    case (false, let host?): "Add the key for \(host)"
    }
  }

  static func keyDialogSubtitle(customHost: String?) -> String {
    guard let customHost else {
      return "The key is checked first, then kept in the Keychain on this device."
    }
    return "The key is checked with \(customHost) first, then kept in the Keychain on this device. "
      + "It is sent to that server, not to OpenAI."
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
    SetupParagraph(PrivacyCopy.promise(customServer: model.settings.apiBaseURL != nil))
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
          description: "So a dictation that failed can be tried again. Deleted with its history entry.",
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
  /// The whole promise in three short sentences: where things are kept, where your voice
  /// goes, and what Open Wisper does not have.
  static func promise(customServer: Bool) -> String {
    let destination = customServer ? "your custom server" : "OpenAI"
    return "Everything is stored on this device, as files you can read. Your voice goes only to "
      + "\(destination), with your own key. There is no account and no tracking."
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
    PermissionsList()
    SetupParagraph("You can leave any of these off.", style: .caption)
  }
}

// MARK: - About

struct AboutSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Wordmark(size: 24)
    Card(padding: 0) {
      SettingRow("Version \(AppVersion.text())", description: AboutCopy.tagline) {
        // Only where the app updates itself: on iPhone the App Store does it.
        if let check = model.host.checkForUpdates {
          Button("Check for updates", action: check)
            .buttonStyle(.wisper(.secondary, size: .small))
        }
      }
      SettingsDivider()
      SettingRow("Open source", description: "MIT licence. Read the code, change it, share it.") {
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

enum AboutCopy {
  static let tagline = "Voice dictation and meeting notes that stay on your device."
}
