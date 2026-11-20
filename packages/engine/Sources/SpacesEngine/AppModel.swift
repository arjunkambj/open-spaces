import Foundation
import Observation
import SpacesDomain

/// What the host app (macOS or iOS) offers to shared screens.
public struct HostActions: Sendable {
  /// Path of the bundled `spaces` agent tool, when the platform has one.
  public var agentToolPath: String?
  /// Folder that holds the library, when it can be shown to the user.
  public var dataFolder: URL?
  /// Turns "open at login" on or off.
  public var setLaunchAtLogin: @MainActor @Sendable (Bool) -> Void
  /// Shows a file or folder in the system file browser.
  public var reveal: @MainActor @Sendable (URL) -> Void
  /// Global shortcuts changed: the host must re-register them.
  public var shortcutsChanged: @MainActor @Sendable () -> Void
  /// Looks for a new version of the app now and shows what it finds.
  /// `nil` where the app is updated some other way (the App Store on iPhone, a demo).
  public var checkForUpdates: (@MainActor @Sendable () -> Void)?

  public init(
    agentToolPath: String? = nil,
    dataFolder: URL? = nil,
    setLaunchAtLogin: @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
    reveal: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
    shortcutsChanged: @escaping @MainActor @Sendable () -> Void = {},
    checkForUpdates: (@MainActor @Sendable () -> Void)? = nil
  ) {
    self.agentToolPath = agentToolPath
    self.dataFolder = dataFolder
    self.setLaunchAtLogin = setLaunchAtLogin
    self.reveal = reveal
    self.shortcutsChanged = shortcutsChanged
    self.checkForUpdates = checkForUpdates
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
    /// Writes dictated words while the person is still speaking, when the chosen model can.
    /// `nil` to always transcribe the finished recording.
    public var liveTranscriber: (any LiveTranscriber)?
    public var languageModel: any LanguageModel
    public var target: any TextTarget
    public var permissions: any Permissions
    public var host: HostActions
    /// Asks the server the settings name whether a key works. Throws `SpacesError` when it does not.
    public var checkAPIKey: @Sendable (String) async throws -> Void
    /// Asks Anthropic whether a key works, for Claude models. Throws `SpacesError` when it does not.
    public var checkClaudeKey: @Sendable (String) async throws -> Void

    public init(
      library: any Library,
      secrets: any SecretStore,
      capture: any AudioCapture,
      transcriber: any Transcriber,
      liveTranscriber: (any LiveTranscriber)? = nil,
      languageModel: any LanguageModel,
      target: any TextTarget,
      permissions: any Permissions,
      host: HostActions = HostActions(),
      checkAPIKey: @escaping @Sendable (String) async throws -> Void,
      checkClaudeKey: @escaping @Sendable (String) async throws -> Void
    ) {
      self.library = library
      self.secrets = secrets
      self.capture = capture
      self.transcriber = transcriber
      self.liveTranscriber = liveTranscriber
      self.languageModel = languageModel
      self.target = target
      self.permissions = permissions
      self.host = host
      self.checkAPIKey = checkAPIKey
      self.checkClaudeKey = checkClaudeKey
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
  private let checkClaudeKey: @Sendable (String) async throws -> Void

  // Live copy of the library
  public private(set) var settings = Settings()
  public private(set) var words: [DictionaryWord] = []
  public private(set) var snippets: [Snippet] = []
  public private(set) var dictations: [Dictation] = []
  public private(set) var meetingList: [Meeting] = []
  /// Whether a key is saved for the server the settings name right now. A key saved for
  /// another server does not count: it is never sent to this one.
  public private(set) var hasAPIKey = false
  /// Whether a key for Anthropic is saved, so Claude models can be used.
  public private(set) var hasClaudeKey = false
  /// False until the first `load()` has finished.
  public private(set) var isLoaded = false
  /// The most recent error from `run`, for screens to show. Set to `nil` to dismiss.
  public var errorMessage: String?

  @ObservationIgnored private var observer: Task<Void, Never>?
  /// The newest settings change made here that is on its way to the library. Changes are
  /// stored one after another, in the order they were made.
  @ObservationIgnored private var settingsWrite: Task<Void, Never>?
  /// How many settings changes made here are not stored yet. While there are any, what the
  /// library holds is older than what is on screen and must not be shown.
  @ObservationIgnored private var settingsWrites = 0
  /// Goes up with every settings change made here, so a read that began before a change
  /// knows it is out of date.
  @ObservationIgnored private var settingsEpoch = 0
  /// What the host was last told about "open at login" by a change made here, until that
  /// change is known to be stored.
  @ObservationIgnored private var launchAtLoginTold: Bool?

  public init(_ dependencies: Dependencies) {
    library = dependencies.library
    secrets = dependencies.secrets
    capture = dependencies.capture
    permissions = dependencies.permissions
    host = dependencies.host
    checkAPIKey = dependencies.checkAPIKey
    checkClaudeKey = dependencies.checkClaudeKey
    let checked = AddressChecked(
      library: dependencies.library,
      transcriber: dependencies.transcriber,
      languageModel: dependencies.languageModel
    )
    dictation = DictationEngine(
      library: dependencies.library,
      capture: dependencies.capture,
      transcriber: checked,
      // The engine itself opens no live session while the address cannot be used.
      liveTranscriber: dependencies.liveTranscriber,
      languageModel: checked,
      target: dependencies.target
    )
    meetings = MeetingEngine(
      library: dependencies.library,
      capture: dependencies.capture,
      transcriber: checked,
      languageModel: checked
    )
  }

  public var stats: DictationStats { DictationStats(dictations) }

  /// Reads everything once and then keeps the copy fresh. Safe to call again.
  ///
  /// The first call also tidies up after a quit in the middle of a dictation
  /// (`DictationEngine.recoverUnfinished`).
  public func load() async {
    let firstLoad = observer == nil
    if observer == nil {
      let stream = library.changes()
      observer = Task { [weak self] in
        for await change in stream {
          await self?.refresh([change])
        }
      }
    }
    await refresh(Set(LibraryChange.allCases))
    await refreshKeyState()
    isLoaded = true
    if firstLoad { await dictation.recoverUnfinished() }
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
      errorMessage = message(for: error)
      return false
    }
  }

  /// Changes settings: the copy updates at once, the library right after.
  ///
  /// What screens see never jumps back to an older value while changes are on their way to
  /// the library, and when a change cannot be stored the copy goes back to what is stored
  /// (and `errorMessage` says why).
  public func update(_ change: @escaping @Sendable (inout Settings) -> Void) {
    let before = settings
    change(&settings)
    let after = settings
    if before.launchAtLogin != after.launchAtLogin {
      host.setLaunchAtLogin(after.launchAtLogin)
      launchAtLoginTold = after.launchAtLogin
    }
    if before.apiBaseURL != after.apiBaseURL { Task { await refreshKeyState() } }
    settingsEpoch += 1
    settingsWrites += 1
    let earlier = settingsWrite
    let write = Task {
      // One after another, in the order the changes were made.
      await earlier?.value
      await attempt { model in
        try await model.library.updateSettings(change)
        if before.shortcuts != after.shortcuts { model.host.shortcutsChanged() }
      }
    }
    settingsWrite = write
    // What follows the write is kept out of the chain, so the next change never waits for a read.
    Task {
      await write.value
      settingsWrites -= 1
      guard settingsWrites == 0 else { return }
      // Everything changed here has been tried. Show what is really stored: after a failure
      // that takes back the value that was not saved, and otherwise it picks up what somebody
      // else changed in the meantime.
      await refresh([.settings])
      guard settingsWrites == 0, let told = launchAtLoginTold else { return }
      launchAtLoginTold = nil
      if told != settings.launchAtLogin { host.setLaunchAtLogin(settings.launchAtLogin) }
    }
  }

  /// Checks a key with the server the settings name and stores it, for that server, when it
  /// works. Throws `SpacesError` when it does not: `.invalidServerAddress` when the custom
  /// server address cannot be used (nothing is sent anywhere then).
  public func saveAPIKey(_ key: String) async throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw SpacesError.missingAPIKey }
    // The stored settings decide where the key is checked, so they decide whose key it is.
    await settingsWrite?.value
    let server = try await library.settings().apiServer()
    try await checkAPIKey(trimmed)
    try await secrets.setAPIKey(trimmed, host: server.host)
    // The copy of the settings may be a moment behind the library (a screen can store the
    // address and save the key in one go), so catch up before saying whether there is a key.
    await refresh([.settings])
    await refreshKeyState()
  }

  /// Removes the key saved for the server the settings name. Throws `SpacesError` when the
  /// key could not be removed.
  public func removeAPIKey() async throws {
    await settingsWrite?.value
    let server = try await library.settings().apiServer()
    try await secrets.setAPIKey(nil, host: server.host)
    await refreshKeyState()
  }

  /// Checks a key with Anthropic and stores it, for Anthropic, when it works. Claude models
  /// use it. Throws `SpacesError` when it does not work.
  public func saveClaudeKey(_ key: String) async throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw SpacesError.anthropic(.missingAPIKey) }
    try await checkClaudeKey(trimmed)
    try await secrets.setAPIKey(trimmed, host: APIServer.anthropicHost)
    await refreshKeyState()
  }

  /// Removes the Anthropic key. Throws `SpacesError` when it could not be removed.
  public func removeClaudeKey() async throws {
    try await secrets.setAPIKey(nil, host: APIServer.anthropicHost)
    await refreshKeyState()
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
      if changes.contains(.settings) { try await refreshSettings() }
      if changes.contains(.words) { words = try await library.words() }
      if changes.contains(.snippets) { snippets = try await library.snippets() }
      if changes.contains(.dictations) {
        let history = try await library.dictations()
        // The dictation being turned into text right now has a "not finished" entry on disk,
        // in case the app quits. It is not a failure to show unless that happens.
        dictations = history.filter { $0.id != dictation.unfinished }
      }
      if changes.contains(.meetings) { meetingList = try await library.meetings() }
    } catch {
      errorMessage = message(for: error)
    }
  }

  /// Takes the stored settings as the copy, unless a change made here is newer than them.
  private func refreshSettings() async throws {
    guard settingsWrites == 0 else { return }
    let epoch = settingsEpoch
    let stored = try await library.settings()
    // A change made here while the read was under way is newer than what was read.
    guard epoch == settingsEpoch, settingsWrites == 0 else { return }
    let server = settings.apiBaseURL
    if settings != stored { settings = stored }
    // Also reached when an agent or a hand edit changes the address in the settings file.
    if stored.apiBaseURL != server { await refreshKeyState() }
  }

  /// Works out `hasAPIKey` for the server the settings name now, and `hasClaudeKey`.
  private func refreshKeyState() async {
    hasClaudeKey = ((try? await secrets.apiKey(for: APIServer.anthropicHost)) ?? nil) != nil
    let address = settings.apiBaseURL
    var saved = false
    if let server = try? APIServer(address: address) {
      saved = ((try? await secrets.apiKey(for: server.host)) ?? nil) != nil
    }
    // The address changed again while the key was being read: that change asks again.
    guard address == settings.apiBaseURL else { return }
    hasAPIKey = saved
  }

  /// The message for an error, naming the server the person set when it is not OpenAI.
  private func message(for error: any Error) -> String {
    guard let known = error as? SpacesError, let server = try? settings.apiServer() else {
      return error.localizedDescription
    }
    return known.message(server: server)
  }
}

/// Sends nothing while the custom server address in the settings cannot be used.
///
/// The OpenAI adapter refuses such an address too, when it is handed the address as text.
/// This holds whatever the app wired in, for dictation and for meetings: a mistyped address
/// is an error (`SpacesError.invalidServerAddress`), and never a reason to send audio to
/// OpenAI instead. Settings that cannot be read send nothing either. A prompt for a Claude
/// model goes to Anthropic, not to that server, so the address does not hold it up.
struct AddressChecked: Transcriber, LanguageModel {
  let library: any Library
  let transcriber: any Transcriber
  let languageModel: any LanguageModel

  func transcribe(_ request: TranscriptionRequest) async throws -> Transcript {
    _ = try await library.settings().apiServer()
    return try await transcriber.transcribe(request)
  }

  func complete(_ request: CompletionRequest) async throws -> String {
    let settings = try await library.settings()
    if !Settings.isClaude(request.model) { _ = try settings.apiServer() }
    return try await languageModel.complete(request)
  }

  func prepare() async {
    guard (try? await library.settings().apiServer()) != nil else { return }
    await transcriber.prepare()
  }
}

extension AppModel {
  /// An app model backed entirely by in-memory fakes and made-up data, for
  /// demos and snapshots. Call `load()` before showing it.
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
        host: HostActions(agentToolPath: "/Applications/Spaces.app/Contents/MacOS/spaces"),
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
