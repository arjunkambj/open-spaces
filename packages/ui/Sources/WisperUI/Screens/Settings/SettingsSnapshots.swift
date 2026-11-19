import SwiftUI
import WisperDomain
import WisperEngine

/// Snapshot cases for this area. See `SnapshotCase`.
enum SettingsSnapshots {
  /// The size of the settings card inside the Mac settings window.
  private static let card = CGSize(width: 860, height: 600)
  private static let canvas = SnapshotCase.Canvas.custom(width: card.width + 60, height: card.height + 60)

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

  @MainActor private static func mac(
    _ name: String,
    _ preview: SettingsPreview,
    model: (@MainActor () -> AppModel)? = { SetupSnapshotModels.make() }
  ) -> SnapshotCase {
    SnapshotCase(name, canvas: canvas, model: model) {
      SettingsScreen(shortcuts: AnyView(ShortcutsStandIn()), onClose: {}, preview: preview)
        .frame(width: card.width, height: card.height)
        .modalSurface()
    }
  }

  @MainActor private static func phone(
    _ name: String,
    _ preview: SettingsPreview,
    model: (@MainActor () -> AppModel)? = { SetupSnapshotModels.make(onPhone: true) }
  ) -> SnapshotCase {
    SnapshotCase(name, canvas: .phone, model: model) {
      SettingsScreen(onClose: {}, preview: preview)
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
  static func make(
    onboarded: Bool = true,
    hasAPIKey: Bool = true,
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
          .appendingPathComponent("Library/Application Support/Open Wisper", isDirectory: true)
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
        secrets: InMemorySecretStore(apiKey: hasAPIKey ? "sk-demo" : nil),
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
