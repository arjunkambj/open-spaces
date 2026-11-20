import SpacesDomain
import SpacesEngine
import SwiftUI

// MARK: - General

struct GeneralSettings: View {
  /// The platform's own row for how the app looks, when it has one.
  var appearance: AnyView?
  /// The Mac app's own row about the floating pill, when it has one.
  var pill: AnyView?

  @Environment(AppModel.self) private var model
  @Environment(\.spacesIdiom) private var idiom
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
            description: "A small bar at the edge of the screen. It shows when Spaces is listening.",
            isOn: model.settingBinding(\.showPill)
          )
          if let pill {
            SettingsDivider()
            pill
          }
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
  @Environment(\.spacesIdiom) private var idiom
  @State private var computerAudioIsBlocked = false
  /// Calendar access was refused: the calendar toggle says how to allow it.
  @State private var calendarIsBlocked = false

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
        if model.calendar != nil {
          ToggleRow(
            "Offer to record calendar calls",
            description: calendarIsBlocked
              ? "Spaces may not read your calendar, so it cannot offer. Allow it in System Settings, "
                + "under Privacy & Security, Calendars."
              : "When a call on your calendar starts, Spaces asks if it should record. The meeting "
                + "gets the event's name and who was invited.",
            isOn: calendarOffers
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
          .buttonStyle(.spaces(.tertiary, size: .small))
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
          // Access taken away while the offers are on. (A refusal while off is kept until the next try.)
          if model.settings.meetings.offerCalendarMeetings {
            let refused = permissions.status(.calendar) != .granted
            if refused != calendarIsBlocked { calendarIsBlocked = refused }
          }
          try? await Task.sleep(for: .seconds(1))
        }
      }
  }

  /// Turning the offers on asks for calendar access first. Without it, they stay off.
  private var calendarOffers: Binding<Bool> {
    Binding(
      get: { model.settings.meetings.offerCalendarMeetings },
      set: { isOn in
        guard isOn else {
          calendarIsBlocked = false
          model.update { $0.meetings.offerCalendarMeetings = false }
          return
        }
        Task {
          let allowed = await model.permissions.request(.calendar) == .granted
          calendarIsBlocked = !allowed
          if allowed { model.update { $0.meetings.offerCalendarMeetings = true } }
        }
      }
    )
  }
}

// MARK: - OpenAI

struct OpenAISettings: View {
  @Binding var dialog: SettingsDialog?

  @Environment(AppModel.self) private var model
  @Environment(\.spacesIdiom) private var idiom
  @State private var typingTranscriptionModel = false
  @State private var typingTextModel = false

  var body: some View {
    // The stored address: the key state (`hasAPIKey`) is about the server it names.
    let server = ServerAddress(model.settings.apiBaseURL ?? "")
    PageSection("OpenAI") {
      Card(padding: 0) {
        HStack(alignment: .center, spacing: Spaces.Space.l) {
          VStack(alignment: .leading, spacing: Spaces.Space.xs) {
            HStack(spacing: Spaces.Space.s) {
              Text(server.customHost == nil ? APIKeyField.openAILabel : APIKeyField.serverLabel)
                .spacesText(.bodyStrong)
              // A server of the person's own may need no key, so having none is not a fault there.
              Badge(
                OpenAICopy.keyBadge(hasKey: model.hasAPIKey, customHost: server.customHost),
                tone: model.hasAPIKey ? .success : server.customHost == nil ? .warning : .neutral
              )
            }
            Text(OpenAICopy.keyStatus(hasKey: model.hasAPIKey, customHost: server.customHost))
              .spacesText(.caption)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, SetupMetrics.rowInset)
        .padding(.top, Spaces.Space.l)
        HStack(spacing: Spaces.Space.s) {
          Button(model.hasAPIKey ? "Change key" : "Add key") { dialog = .apiKey }
            .buttonStyle(.spaces(model.hasAPIKey ? .secondary : .primary, size: .small))
          if model.hasAPIKey {
            Button("Remove key") { dialog = .removeKey }
              .buttonStyle(.spaces(.ghost, size: .small))
          }
          Spacer(minLength: Spaces.Space.s)
          if idiom == .mac, server.customHost == nil { SetupLink("Get a key", url: SetupLinks.openAIKeys) }
        }
        .padding(.horizontal, SetupMetrics.rowInset)
        .padding(.top, Spaces.Space.m)
        .padding(.bottom, Spaces.Space.l)
      }
      // Said only while it is true: with a server of the person's own, nothing goes to OpenAI.
      if server.customHost == nil {
        SetupParagraph(
          "You pay OpenAI directly for what you use. Spaces adds nothing on top.",
          style: .caption
        )
        if idiom == .phone { SetupLink("Get a key", url: SetupLinks.openAIKeys) }
      }
    }
    PageSection("Claude") {
      Card(padding: 0) {
        VStack(alignment: .leading, spacing: Spaces.Space.xs) {
          HStack(spacing: Spaces.Space.s) {
            Text(ClaudeKeyField.label).spacesText(.bodyStrong)
            Badge(
              model.hasClaudeKey ? "Connected" : "Not connected",
              tone: model.hasClaudeKey ? .success : model.settings.usesClaude ? .warning : .neutral
            )
          }
          Text(ClaudeCopy.keyStatus(hasKey: model.hasClaudeKey, usesClaude: model.settings.usesClaude))
            .spacesText(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .padding(.horizontal, SetupMetrics.rowInset)
        .padding(.top, Spaces.Space.l)
        HStack(spacing: Spaces.Space.s) {
          Button(model.hasClaudeKey ? "Change key" : "Add key") { dialog = .claudeKey }
            .buttonStyle(.spaces(model.hasClaudeKey ? .secondary : .primary, size: .small))
          if model.hasClaudeKey {
            Button("Remove key") { dialog = .removeClaudeKey }
              .buttonStyle(.spaces(.ghost, size: .small))
          }
          Spacer(minLength: Spaces.Space.s)
          if idiom == .mac { SetupLink("Get a key", url: SetupLinks.anthropicKeys) }
        }
        .padding(.horizontal, SetupMetrics.rowInset)
        .padding(.top, Spaces.Space.m)
        .padding(.bottom, Spaces.Space.l)
      }
      SetupParagraph(
        "Optional. Pick a Claude model as the text model below to have Claude tidy your words and "
          + "write meeting notes. OpenAI still turns your voice into text. You pay Anthropic directly.",
        style: .caption
      )
      if idiom == .phone { SetupLink("Get a key", url: SetupLinks.anthropicKeys) }
    }
    PageSection("Models") {
      Card(padding: 0) {
        ModelPicker(
          title: "Transcription model",
          description: "Turns your voice into text.",
          suggested: SpacesDomain.Settings.suggestedTranscriptionModels,
          current: model.settings.transcriptionModel,
          isTyping: $typingTranscriptionModel
        ) { name in
          model.update { $0.transcriptionModel = name }
        }
        SettingsDivider()
        ModelPicker(
          title: "Text model",
          description:
            "Tidies dictations, follows spoken commands and writes meeting notes. "
            + "Claude models use your Anthropic key.",
          suggested: SpacesDomain.Settings.suggestedTextModels,
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
    case (true, nil): "Saved on this device only. It is sent only to OpenAI."
    case (true, let host?): "Saved on this device only. It is sent to \(host), not to OpenAI."
    case (false, nil): "Add your key to start dictating. It is saved on this device only."
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
      return "The key is checked first, then saved on this device only."
    }
    return "The key is checked with \(customHost) first, then saved on this device only. "
      + "It is sent to that server, not to OpenAI."
  }
}

enum ClaudeCopy {
  static func keyStatus(hasKey: Bool, usesClaude: Bool) -> String {
    switch (hasKey, usesClaude) {
    case (true, _): "Saved on this device only. It is sent only to Anthropic."
    case (false, true): "Your text model is a Claude model. Add your Anthropic key to use it."
    case (false, false): "Add a key to use Claude models. It is saved on this device only."
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
      .padding(.bottom, Spaces.Space.l)
    }
  }
}

// MARK: - Agents

struct AgentSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    SetupParagraph(
      "AI agents such as Claude Code, Cursor or any tool that speaks MCP can read and update your "
        + "meeting notes through spaces, a small program that comes with Spaces. "
        + "It works only with the files on this device."
    )
    if let path = model.host.agentToolPath {
      AgentConnections(tools: AgentStatus.list(model.agentSessions))
      PageSection("Claude Code") {
        VStack(alignment: .leading, spacing: Spaces.Space.s) {
          CopyBlock("Claude Code command", text: AgentSetup.claudeCommand(toolPath: path))
          SetupParagraph("Run this once in a terminal.", style: .caption)
        }
      }
      PageSection("Cursor, Claude Desktop and other tools") {
        VStack(alignment: .leading, spacing: Spaces.Space.s) {
          CopyBlock("Settings for other tools", text: AgentSetup.jsonConfig(toolPath: path))
          SetupParagraph("Paste this into the MCP settings of your tool.", style: .caption)
        }
      }
      PageSection("Where the program is") {
        CopyBlock("Path of the spaces program", text: path)
      }
    } else {
      Banner(
        .info,
        title: "This is a Mac feature",
        message: "The spaces program comes with Spaces for Mac. Set up your agents there."
      )
    }
    PageSection("What agents can do") {
      Card {
        VStack(alignment: .leading, spacing: Spaces.Space.l) {
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
            detail: "spaces cannot read your OpenAI key and makes no network calls."
          )
        }
      }
      SetupLink("Read the guide", url: SetupLinks.agentsGuide)
    }
  }
}

/// The AI tools that used Spaces in the last day, and whether they are connected now.
private struct AgentConnections: View {
  let tools: [AgentStatus]

  var body: some View {
    PageSection("Connected") {
      Card(padding: 0) {
        if tools.isEmpty {
          SettingRow(
            "No AI tool is connected",
            description: "Add Spaces to your AI tool below. It shows up here once it uses Spaces."
          ) {
            AgentDot(isConnected: false)
          }
        } else {
          TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(spacing: 0) {
              ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                if index > 0 { SettingsDivider() }
                SettingRow(
                  tool.version.map { "\(tool.name) \($0)" } ?? tool.name,
                  description: tool.detail(now: timeline.date)
                ) {
                  AgentDot(isConnected: tool.isConnected)
                }
                .accessibilityElement(children: .combine)
              }
            }
          }
        }
      }
    }
  }
}

// MARK: - Privacy

struct PrivacySettings: View {
  @Binding var dialog: SettingsDialog?

  @Environment(AppModel.self) private var model
  @Environment(\.spacesIdiom) private var idiom

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
            .buttonStyle(.spaces(.secondary, size: .small))
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
              .buttonStyle(.spaces(.secondary, size: .small))
          }
        }
      }
    }
  }
}

enum PrivacyCopy {
  /// The whole promise in three short sentences: where things are kept, where your voice
  /// goes, and what Spaces does not have.
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
      SettingRow("Version \(AppVersion.text)", description: AboutCopy.tagline) {
        // Only where the app updates itself: on iPhone the App Store does it.
        if let check = model.host.checkForUpdates {
          Button("Check for updates", action: check)
            .buttonStyle(.spaces(.secondary, size: .small))
        }
      }
      SettingsDivider()
      SettingRow("Open source", description: "MIT licence. Read the code, change it, share it.") {
        SetupLink("GitHub", url: SetupLinks.repository)
      }
    }
    SetupParagraph(
      "Spaces is an independent project. It is not made by, or connected to, OpenAI or any other "
        + "dictation app.",
      style: .caption
    )
  }
}

enum AboutCopy {
  static let tagline = "Voice dictation and meeting notes that stay on your device."
}
