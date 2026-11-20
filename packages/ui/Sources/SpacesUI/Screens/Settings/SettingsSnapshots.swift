import SpacesDomain
import SpacesEngine
import SwiftUI

/// Snapshot cases for this area. See `SnapshotCase`.
enum SettingsSnapshots {
  /// The size of the settings card inside the Mac settings window.
  private static let card = CGSize(width: 860, height: 600)

  @MainActor static var cases: [SnapshotCase] {
    var cases: [SnapshotCase] = []
    for section in SettingsSection.allCases {
      cases.append(mac("settings-\(section.rawValue)", SettingsPreview(section: section)))
      cases.append(phone("settings-\(section.rawValue)-phone", SettingsPreview(section: section)))
    }
    cases += [
      phone("settings-list-phone", SettingsPreview()),
      mac(
        "settings-agents-none",
        SettingsPreview(section: .agents),
        model: { SetupSnapshotModels.make(agents: []) }
      ),
      mac(
        "settings-agents-several",
        SettingsPreview(section: .agents),
        model: { SetupSnapshotModels.make(agents: SetupSnapshotModels.severalAgents()) }
      ),
      mac(
        "settings-openai-nokey",
        SettingsPreview(section: .openAI),
        model: { SetupSnapshotModels.make(hasAPIKey: false) }
      ),
      mac(
        "settings-openai-custom",
        SettingsPreview(section: .openAI),
        model: {
          SetupSnapshotModels.make(settings: {
            $0.textModel = "llama-3.3-70b"
            $0.apiBaseURL = "http://localhost:11434/v1"
          })
        }
      ),
      // The address was changed to another server: the key saved for OpenAI is not used there.
      mac(
        "settings-openai-other-server",
        SettingsPreview(section: .openAI),
        model: {
          SetupSnapshotModels.make(
            keyHost: APIServer.openAIHost,
            settings: { $0.apiBaseURL = "https://proxy.example.com/v1" }
          )
        }
      ),
      // Tall, so the server part at the foot of the section shows.
      mac(
        "settings-openai-not-private",
        SettingsPreview(section: .openAI),
        height: 860,
        model: { SetupSnapshotModels.make(settings: { $0.apiBaseURL = "http://models.example.com/v1" }) }
      ),
      phone(
        "settings-openai-not-private-phone",
        SettingsPreview(section: .openAI),
        height: 1_180,
        model: {
          SetupSnapshotModels.make(
            keyHost: APIServer.openAIHost,
            onPhone: true,
            settings: { $0.apiBaseURL = "http://192.168.1.20:8080/v1" }
          )
        }
      ),
      mac(
        "settings-key-dialog-server",
        SettingsPreview(section: .openAI, dialog: .apiKey),
        model: {
          SetupSnapshotModels.make(
            keyHost: APIServer.openAIHost,
            settings: { $0.apiBaseURL = "https://proxy.example.com/v1" }
          )
        }
      ),
      mac(
        "settings-key-dialog",
        SettingsPreview(
          section: .openAI,
          dialog: .apiKey,
          keyDraft: "not-a-key",
          keyError: APIKeyEntry.message(for: SpacesError.invalidAPIKey)
        )
      ),
      phone("settings-key-dialog-phone", SettingsPreview(section: .openAI, dialog: .apiKey)),
      mac("settings-remove-key-dialog", SettingsPreview(section: .openAI, dialog: .removeKey)),
      mac("settings-delete-history-dialog", SettingsPreview(section: .privacy, dialog: .deleteHistory)),
      phone(
        "settings-delete-history-dialog-phone",
        SettingsPreview(section: .privacy, dialog: .deleteHistory)
      ),
      mac(
        "settings-permissions-missing",
        SettingsPreview(section: .permissions),
        model: { SetupSnapshotModels.make(permissions: [.microphone: .granted, .accessibility: .denied]) }
      ),
      mac(
        "settings-meetings-warning",
        SettingsPreview(section: .meetings),
        model: { SetupSnapshotModels.make(permissions: [.microphone: .granted, .accessibility: .granted]) }
      ),
      // Calendar offers are on, but access to the calendar was taken away.
      mac(
        "settings-meetings-calendar-blocked",
        SettingsPreview(section: .meetings),
        model: {
          SetupSnapshotModels.make(
            permissions: [
              .microphone: .granted, .accessibility: .granted, .systemAudio: .granted, .calendar: .denied,
            ],
            settings: { $0.meetings.offerCalendarMeetings = true }
          )
        }
      ),
      // No iPhone has the spaces program. This one shows that the code wraps in a narrow box.
      phone(
        "settings-agents-narrow",
        SettingsPreview(section: .agents),
        model: { SetupSnapshotModels.make() }
      ),
      phone(
        "settings-agents-iphone",
        SettingsPreview(section: .agents),
        model: { SetupSnapshotModels.make(onPhone: true) }
      ),
      phone(
        "settings-permissions-iphone",
        SettingsPreview(section: .permissions),
        model: { SetupSnapshotModels.make(permissions: [:], onPhone: true) }
      ),
    ]
    return cases
  }

  /// - height: a taller card than the window's, to show a section down to its foot.
  @MainActor private static func mac(
    _ name: String,
    _ preview: SettingsPreview,
    height: CGFloat = card.height,
    model: @escaping @MainActor () -> AppModel = { SetupSnapshotModels.make() }
  ) -> SnapshotCase {
    SnapshotCase(name, canvas: .custom(width: card.width + 60, height: height + 60), model: model) {
      SettingsScreen(shortcuts: AnyView(ShortcutsStandIn()), onClose: {}, preview: preview)
        .frame(width: card.width, height: height)
        .modalSurface()
    }
  }

  /// - height: a taller screen than an iPhone's, to show a section down to its foot.
  @MainActor private static func phone(
    _ name: String,
    _ preview: SettingsPreview,
    height: CGFloat? = nil,
    model: @escaping @MainActor () -> AppModel = { SetupSnapshotModels.make(onPhone: true) }
  ) -> SnapshotCase {
    let canvas = height.map {
      SnapshotCase.Canvas.custom(width: SnapshotCase.Canvas.phone.size.width, height: $0)
    }
    return SnapshotCase(name, canvas: canvas ?? .phone, model: model) {
      if canvas == nil {
        SettingsScreen(onClose: {}, preview: preview)
      } else {
        // A custom canvas is drawn as a Mac's: say it is a phone, on the phone's background.
        SettingsScreen(onClose: {}, preview: preview)
          .environment(\.spacesIdiom, .phone)
          .background(Spaces.Color.panel)
      }
    }
  }
}

/// Stands in for the shortcut editor the Mac app supplies.
private struct ShortcutsStandIn: View {
  var body: some View {
    Card(padding: 0) {
      ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
        if index > 0 { SettingsDivider() }
        SettingRow(action.label, description: action.help) {
          KeyCapRow(["fn"])
        }
      }
    }
  }
}

/// App models for the snapshots of settings and onboarding: made-up data on in-memory fakes.
@MainActor
enum SetupSnapshotModels {
  /// Claude Code in two chats, Cursor stopped an hour ago, and a tool that gave no name.
  static func severalAgents(now: Date = Date()) -> [AgentSession] {
    let claude = AgentClient(name: "claude-code", version: "2.1.0")
    return [
      AgentSession(pid: 4_242, client: claude, startedAt: now.addingTimeInterval(-7_200), lastActiveAt: now),
      AgentSession(pid: 4_300, client: claude, startedAt: now.addingTimeInterval(-600)),
      AgentSession(
        pid: 3_100,
        client: AgentClient(name: "cursor-vscode", version: "1.4.2"),
        startedAt: now.addingTimeInterval(-10_000),
        lastActiveAt: now.addingTimeInterval(-3_700),
        endedAt: now.addingTimeInterval(-3_700)
      ),
      AgentSession(pid: 2_000, client: AgentClient(name: ""), startedAt: now.addingTimeInterval(-20_000)),
    ]
  }

  /// - keyHost: the server the saved key is for. `nil` means the server the settings name, so
  ///   the key counts; name another host to show a key that is not used.
  static func make(
    onboarded: Bool = true,
    hasAPIKey: Bool = true,
    keyHost: String? = nil,
    permissions: [Permission: PermissionStatus] = [
      .microphone: .granted, .accessibility: .granted, .systemAudio: .granted,
    ],
    onPhone: Bool = false,
    agents: [AgentSession] = SampleData.agents(),
    settings change: (inout SpacesDomain.Settings) -> Void = { _ in }
  ) -> AppModel {
    var settings = SpacesDomain.Settings(
      userName: onboarded ? "Alex" : "",
      onboardedAt: onboarded ? Date().addingTimeInterval(-20 * 86_400) : nil
    )
    change(&settings)
    let devices =
      onPhone
      ? [AudioDevice(id: "iphone", name: "iPhone Microphone", isDefault: true)]
      : [
        AudioDevice(id: "built-in", name: "MacBook Pro Microphone", isDefault: true),
        AudioDevice(id: "headset", name: "Studio Headset"),
      ]
    let host =
      onPhone
      ? HostActions()
      : HostActions(
        agentToolPath: "/Applications/Spaces.app/Contents/MacOS/spaces",
        dataFolder: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
          .appendingPathComponent("Library/Application Support/Spaces", isDirectory: true),
        // So the About section shows its button in a picture. It does nothing here.
        checkForUpdates: {}
      )
    return AppModel(
      AppModel.Dependencies(
        library: InMemoryLibrary(
          settings: settings,
          words: SampleData.words(),
          snippets: SampleData.snippets(),
          dictations: SampleData.dictations(),
          meetings: SampleData.meetings(),
          agents: agents
        ),
        secrets: InMemorySecretStore(
          apiKey: hasAPIKey ? "sk-demo" : nil,
          host: keyHost ?? (try? settings.apiServer())?.host ?? APIServer.openAIHost
        ),
        capture: FakeAudioCapture(devices: devices),
        transcriber: FakeTranscriber(text: "This is a demo dictation."),
        languageModel: FakeLanguageModel(text: "This is a demo dictation."),
        target: FakeTextTarget(),
        permissions: FakePermissions(
          needed: onPhone ? [.microphone] : [.microphone, .accessibility, .systemAudio],
          statuses: permissions
        ),
        calendar: onPhone ? nil : FakeMeetingCalendar(),
        host: host,
        checkAPIKey: { key in
          if !key.hasPrefix("sk-") { throw SpacesError.invalidAPIKey }
        },
        checkClaudeKey: { key in
          if !key.hasPrefix("sk-ant-") { throw SpacesError.anthropic(.invalidAPIKey) }
        }
      )
    )
  }
}
