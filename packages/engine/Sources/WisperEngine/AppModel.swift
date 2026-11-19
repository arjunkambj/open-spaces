import Foundation
import Observation
import WisperDomain

/// What the host app (macOS or iOS) offers to shared screens.
public struct HostActions: Sendable {
  /// Path of the bundled `wisper` agent tool, when the platform has one.
  public var agentToolPath: String?
  /// Folder that holds the library, when it can be shown to the user.
  public var dataFolder: URL?
  /// Turns "open at login" on or off.
  public var setLaunchAtLogin: @MainActor @Sendable (Bool) -> Void
  /// Shows a file or folder in the system file browser.
  public var reveal: @MainActor @Sendable (URL) -> Void
  /// Global shortcuts changed: the host must re-register them.
  public var shortcutsChanged: @MainActor @Sendable () -> Void

  public init(
    agentToolPath: String? = nil,
    dataFolder: URL? = nil,
    setLaunchAtLogin: @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
    reveal: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
    shortcutsChanged: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    self.agentToolPath = agentToolPath
    self.dataFolder = dataFolder
    self.setLaunchAtLogin = setLaunchAtLogin
    self.reveal = reveal
    self.shortcutsChanged = shortcutsChanged
  }
}

/// The one object screens talk to.
///
/// Holds a live copy of the library (kept fresh from `Library.changes()`, so
/// edits made by an agent show up too), the two engines and the platform
/// services. Screens read the cached values and write through `run`.
@MainActor
@Observable
public final class AppModel {
  public struct Dependencies {
    public var library: any Library
    public var secrets: any SecretStore
    public var capture: any AudioCapture
    public var transcriber: any Transcriber
    public var languageModel: any LanguageModel
    public var target: any TextTarget
    public var permissions: any Permissions
    public var host: HostActions
    /// Asks OpenAI whether a key works. Throws `WisperError` when it does not.
    public var checkAPIKey: @Sendable (String) async throws -> Void

    public init(
      library: any Library,
      secrets: any SecretStore,
      capture: any AudioCapture,
      transcriber: any Transcriber,
      languageModel: any LanguageModel,
      target: any TextTarget,
      permissions: any Permissions,
      host: HostActions = HostActions(),
      checkAPIKey: @escaping @Sendable (String) async throws -> Void
    ) {
      self.library = library
      self.secrets = secrets
      self.capture = capture
      self.transcriber = transcriber
      self.languageModel = languageModel
      self.target = target
      self.permissions = permissions
      self.host = host
      self.checkAPIKey = checkAPIKey
    }
  }

  // Services
  public let library: any Library
  public let secrets: any SecretStore
  public let capture: any AudioCapture
  public let permissions: any Permissions
  public let host: HostActions
  public let dictation: DictationEngine
  public let meetings: MeetingEngine
  private let checkAPIKey: @Sendable (String) async throws -> Void

  // Live copy of the library
  public private(set) var settings = Settings()
  public private(set) var words: [DictionaryWord] = []
  public private(set) var snippets: [Snippet] = []
  public private(set) var dictations: [Dictation] = []
  public private(set) var meetingList: [Meeting] = []
  public private(set) var hasAPIKey = false
  /// False until the first `load()` has finished.
  public private(set) var isLoaded = false
  /// The most recent error from `run`, for screens to show. Set to `nil` to dismiss.
  public var errorMessage: String?

  private var observer: Task<Void, Never>?

  public init(_ dependencies: Dependencies) {
    library = dependencies.library
    secrets = dependencies.secrets
    capture = dependencies.capture
    permissions = dependencies.permissions
    host = dependencies.host
    checkAPIKey = dependencies.checkAPIKey
    dictation = DictationEngine(
      library: dependencies.library,
      capture: dependencies.capture,
      transcriber: dependencies.transcriber,
      languageModel: dependencies.languageModel,
      target: dependencies.target
    )
    meetings = MeetingEngine(
      library: dependencies.library,
      capture: dependencies.capture,
      transcriber: dependencies.transcriber,
      languageModel: dependencies.languageModel
    )
  }

  public var stats: DictationStats { DictationStats(dictations) }

  /// Reads everything once and then keeps the copy fresh. Safe to call again.
  public func load() async {
    if observer == nil {
      let stream = library.changes()
      observer = Task { [weak self] in
        for await change in stream {
          await self?.refresh([change])
        }
      }
    }
    await refresh(Set(LibraryChange.allCases))
    hasAPIKey = ((try? await secrets.apiKey()) ?? nil) != nil
    isLoaded = true
  }

  /// Runs a write. Errors land in `errorMessage` instead of being thrown.
  public func run(_ work: @escaping @MainActor @Sendable (AppModel) async throws -> Void) {
    Task { await attempt(work) }
  }

  /// Like `run`, but waits for the write. Returns whether it succeeded.
  @discardableResult
  public func attempt(_ work: @MainActor @Sendable (AppModel) async throws -> Void) async -> Bool {
    do {
      try await work(self)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  /// Changes settings: the copy updates at once, the library right after.
  public func update(_ change: @escaping @Sendable (inout Settings) -> Void) {
    let before = settings
    change(&settings)
    let shortcutsChanged = before.shortcuts != settings.shortcuts
    if before.launchAtLogin != settings.launchAtLogin { host.setLaunchAtLogin(settings.launchAtLogin) }
    run { model in
      try await model.library.updateSettings(change)
      if shortcutsChanged { model.host.shortcutsChanged() }
    }
  }

  /// Checks a key with OpenAI and stores it when it works. Throws `WisperError` when it does not.
  public func saveAPIKey(_ key: String) async throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw WisperError.missingAPIKey }
    try await checkAPIKey(trimmed)
    try await secrets.setAPIKey(trimmed)
    hasAPIKey = true
  }

  public func removeAPIKey() async {
    try? await secrets.setAPIKey(nil)
    hasAPIKey = false
  }

  /// Marks onboarding as finished.
  public func finishOnboarding(userName: String) {
    update { settings in
      settings.userName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
      settings.onboardedAt = Date()
    }
  }

  private func refresh(_ changes: Set<LibraryChange>) async {
    do {
      if changes.contains(.settings) { settings = try await library.settings() }
      if changes.contains(.words) { words = try await library.words() }
      if changes.contains(.snippets) { snippets = try await library.snippets() }
      if changes.contains(.dictations) { dictations = try await library.dictations() }
      if changes.contains(.meetings) { meetingList = try await library.meetings() }
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

extension AppModel {
  /// An app model backed entirely by in-memory fakes and made-up data, for
  /// demos, snapshots and tests. Call `load()` before showing it.
  public static func demo(
    onboarded: Bool = true,
    hasAPIKey: Bool = true,
    permissions: [Permission: PermissionStatus] = [
      .microphone: .granted, .accessibility: .granted, .systemAudio: .granted,
    ]
  ) -> AppModel {
    AppModel(
      Dependencies(
        library: SampleData.library(onboarded: onboarded),
        secrets: InMemorySecretStore(apiKey: hasAPIKey ? "sk-demo" : nil),
        capture: FakeAudioCapture(),
        transcriber: FakeTranscriber(text: "This is a demo dictation."),
        languageModel: FakeLanguageModel(text: "This is a demo dictation."),
        target: FakeTextTarget(),
        permissions: FakePermissions(statuses: permissions),
        host: HostActions(agentToolPath: "/Applications/Open Wisper.app/Contents/MacOS/wisper"),
        checkAPIKey: { key in
          if !key.hasPrefix("sk-") { throw WisperError.invalidAPIKey }
        }
      )
    )
  }
}
