import SwiftUI
import WisperDomain
import WisperEngine

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
          keyError: APIKeyEntry.message(for: WisperError.invalidAPIKey)
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
      // No iPhone has the wisper program. This one shows that the code wraps in a narrow box.
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
          .environment(\.wisperIdiom, .phone)
          .background(Wisper.Color.panel)
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
    settings change: (inout WisperDomain.Settings) -> Void = { _ in }
  ) -> AppModel {
    var settings = WisperDomain.Settings(
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
        agentToolPath: "/Applications/Open Wisper.app/Contents/MacOS/wisper",
        dataFolder: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
          .appendingPathComponent("Library/Application Support/Open Wisper", isDirectory: true),
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
          meetings: SampleData.meetings()
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
          needed: onPhone ? [.microphone] : Permission.allCases,
          statuses: permissions
        ),
        host: host,
        checkAPIKey: { key in
          if !key.hasPrefix("sk-") { throw WisperError.invalidAPIKey }
        }
      )
    )
  }
}
