import Foundation

// The seams of Open Wisper. Each protocol here has a real adapter in another
// package and an in-memory adapter in `Fakes.swift`.
//
//   Library        -> WisperStore.FileLibrary          (files on disk)
//   SecretStore    -> WisperStore.KeychainSecretStore  (Keychain)
//   Transcriber    -> WisperAI.OpenAITranscriber       (OpenAI audio API)
//   LanguageModel  -> WisperAI.OpenAILanguageModel     (OpenAI chat API)
//   AudioCapture   -> WisperAudio.SystemAudioCapture   (AVFoundation / Core Audio)

// MARK: - Library

/// Everything Open Wisper stores, all of it on this device.
///
/// One instance is shared per process. Every write is durable when the call
/// returns. Other processes (the `wisper` agent tool) may write to the same
/// files; `changes()` reports those writes too.
public protocol Library: Sendable {
  func settings() async throws -> Settings
  /// Applies `change` to the stored settings and returns the result.
  @discardableResult
  func updateSettings(_ change: @Sendable (inout Settings) -> Void) async throws -> Settings

  /// Dictionary words, newest first.
  func words() async throws -> [DictionaryWord]
  /// Inserts or replaces by `id`.
  func save(_ word: DictionaryWord) async throws
  func deleteWord(_ id: DictionaryWord.ID) async throws

  /// Snippets, newest first.
  func snippets() async throws -> [Snippet]
  /// Inserts or replaces by `id`.
  func save(_ snippet: Snippet) async throws
  func deleteSnippet(_ id: Snippet.ID) async throws

  /// Dictation history, newest first. `search` matches text case-insensitively;
  /// `nil` or empty returns everything. `limit` caps the count.
  func dictations(search: String?, limit: Int?) async throws -> [Dictation]
  /// Inserts or replaces by `id`. Also applies the history retention setting.
  func save(_ dictation: Dictation) async throws
  /// Deletes the entries and any audio kept for them.
  func deleteDictations(_ ids: Set<Dictation.ID>) async throws
  func deleteAllDictations() async throws
  /// Folder where audio of dictations is kept. Created on demand.
  func dictationAudioDirectory() async throws -> URL

  /// Meetings, newest first. `search` matches title, notes, tags and transcript.
  func meetings(search: String?) async throws -> [Meeting]
  func meeting(_ id: Meeting.ID) async throws -> Meeting?
  /// Inserts or replaces by `id`.
  func save(_ meeting: Meeting) async throws
  /// Deletes the meeting and its audio.
  func deleteMeeting(_ id: Meeting.ID) async throws
  /// Folder where a meeting's audio chunks are written. Created on demand.
  func audioDirectory(forMeeting id: Meeting.ID) async throws -> URL

  /// A stream of what changed, from this process or another one. Each call
  /// returns an independent stream; it ends when the caller stops iterating.
  func changes() -> AsyncStream<LibraryChange>
}

public enum LibraryChange: Sendable, Hashable, CaseIterable {
  case settings, words, snippets, dictations, meetings
}

extension Library {
  public func dictations() async throws -> [Dictation] {
    try await dictations(search: nil, limit: nil)
  }

  public func meetings() async throws -> [Meeting] {
    try await meetings(search: nil)
  }
}

// MARK: - Secrets

/// Holds the user's OpenAI API key. Never written to the library files.
public protocol SecretStore: Sendable {
  func apiKey() async throws -> String?
  /// Pass `nil` to remove the key.
  func setAPIKey(_ key: String?) async throws
}

// MARK: - Transcription

public struct TranscriptionRequest: Sendable {
  /// An audio file on disk (m4a, wav, mp3...).
  public var audio: URL
  public var model: String
  /// ISO 639-1 code, or `nil` to auto-detect.
  public var language: String?
  /// Words the transcriber should prefer (names, jargon).
  public var vocabulary: [String]

  public init(audio: URL, model: String, language: String? = nil, vocabulary: [String] = []) {
    self.audio = audio
    self.model = model
    self.language = language
    self.vocabulary = vocabulary
  }
}

public struct Transcript: Sendable, Equatable {
  public var text: String
  /// Timed pieces, when the model returns them. Times are seconds from the start of the file.
  public var segments: [Segment]
  public var language: String?

  public struct Segment: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
      self.start = start
      self.end = end
      self.text = text
    }
  }

  public init(text: String, segments: [Segment] = [], language: String? = nil) {
    self.text = text
    self.segments = segments
    self.language = language
  }
}

/// Turns an audio file into text.
public protocol Transcriber: Sendable {
  /// Throws `WisperError`. Returns an empty `text` when the audio holds no speech.
  func transcribe(_ request: TranscriptionRequest) async throws -> Transcript
}

// MARK: - Language model

public struct CompletionRequest: Sendable {
  public var model: String
  public var system: String
  public var user: String
  /// When set, the reply must be a JSON object matching this JSON Schema
  /// (given as JSON text). The returned string is then that JSON.
  public var jsonSchema: String?
  public var temperature: Double?
  /// How hard the model should think before answering, or `nil` for the
  /// model's own default. Models that cannot take the value ignore it.
  public var effort: Effort?

  /// Less effort answers sooner. Dictation clean-up wants `.none`; meeting notes can afford more.
  public enum Effort: String, Sendable, CaseIterable {
    case none, low, medium, high
  }

  public init(
    model: String,
    system: String,
    user: String,
    jsonSchema: String? = nil,
    temperature: Double? = nil,
    effort: Effort? = nil
  ) {
    self.model = model
    self.system = system
    self.user = user
    self.jsonSchema = jsonSchema
    self.temperature = temperature
    self.effort = effort
  }
}

/// Answers one prompt with text.
public protocol LanguageModel: Sendable {
  /// Throws `WisperError`.
  func complete(_ request: CompletionRequest) async throws -> String
}

// MARK: - Audio capture

public enum AudioTrack: String, Codable, Sendable, Hashable, CaseIterable {
  /// The user's microphone.
  case microphone
  /// What the computer is playing. macOS only.
  case system
}

public struct AudioDevice: Sendable, Hashable, Identifiable {
  /// Stable unique ID of the device.
  public var id: String
  public var name: String
  public var isDefault: Bool

  public init(id: String, name: String, isDefault: Bool = false) {
    self.id = id
    self.name = name
    self.isDefault = isDefault
  }
}

public struct CaptureRequest: Sendable {
  public var tracks: Set<AudioTrack>
  /// Input device for the microphone track, or `nil` for the system default.
  public var microphoneID: String?
  /// Folder the audio files are written into. Must exist.
  public var directory: URL
  /// When set, each track is cut into files of about this many seconds and
  /// each is emitted as soon as it is finished. When `nil`, one file per
  /// track is emitted after `stop()`.
  public var chunkSeconds: TimeInterval?

  public init(
    tracks: Set<AudioTrack> = [.microphone],
    microphoneID: String? = nil,
    directory: URL,
    chunkSeconds: TimeInterval? = nil
  ) {
    self.tracks = tracks
    self.microphoneID = microphoneID
    self.directory = directory
    self.chunkSeconds = chunkSeconds
  }
}

/// A finished audio file from a capture.
public struct AudioChunk: Sendable, Hashable {
  public var track: AudioTrack
  public var url: URL
  /// Seconds from the start of the capture to the start of this file.
  public var offset: TimeInterval
  public var duration: TimeInterval

  public init(track: AudioTrack, url: URL, offset: TimeInterval, duration: TimeInterval) {
    self.track = track
    self.url = url
    self.offset = offset
    self.duration = duration
  }
}

/// A capture in progress.
public protocol CaptureSession: Sendable {
  /// Loudness of the microphone (or the system track when there is no
  /// microphone), 0...1, about 20 times a second. Ends when the capture ends.
  var levels: AsyncStream<Float> { get }
  /// Finished audio files. Ends after `stop()` has flushed the last file, or
  /// right away after `cancel()`. Iterate it once.
  var chunks: AsyncStream<AudioChunk> { get }
  /// Stops recording and flushes the remaining audio into `chunks`.
  func stop() async
  /// Stops recording and deletes everything not yet emitted.
  func cancel() async
}

/// Records audio into files.
public protocol AudioCapture: Sendable {
  /// Input devices that can be used for the microphone track.
  func microphones() async -> [AudioDevice]
  /// Starts recording. Throws `WisperError.permissionDenied` when access to
  /// the microphone or system audio has not been granted, and
  /// `WisperError.captureFailed` for anything else.
  func start(_ request: CaptureRequest) async throws -> any CaptureSession
}

// MARK: - Errors

public enum Permission: String, Sendable, CaseIterable, Hashable {
  case microphone, accessibility, systemAudio

  public var label: String {
    switch self {
    case .microphone: "Microphone"
    case .accessibility: "Accessibility"
    case .systemAudio: "System audio recording"
    }
  }
}

/// The errors Open Wisper shows to people. Every seam throws these.
public enum WisperError: Error, Sendable, Equatable, LocalizedError {
  case missingAPIKey
  case invalidAPIKey
  case rateLimited
  /// The request never reached OpenAI (offline, timeout).
  case network(String)
  /// OpenAI answered with an error.
  case server(status: Int, message: String)
  case noSpeech
  case permissionDenied(Permission)
  case captureFailed(String)
  case notFound(String)
  case storage(String)
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .missingAPIKey: "Add your OpenAI API key in Settings to start dictating."
    case .invalidAPIKey: "OpenAI did not accept your API key. Check it in Settings."
    case .rateLimited: "OpenAI is limiting requests for your key right now. Try again in a moment."
    case .network(let detail): "Could not reach OpenAI. Check your internet connection. (\(detail))"
    case .server(let status, let message): "OpenAI returned an error (\(status)): \(message)"
    case .noSpeech: "No speech was heard."
    case .permissionDenied(let permission):
      "\(permission.label) access is needed. Turn it on in System Settings."
    case .captureFailed(let detail): "Recording failed: \(detail)"
    case .notFound(let what): "\(what) was not found."
    case .storage(let detail): "Could not read or save your data: \(detail)"
    case .invalidResponse(let detail): "OpenAI sent a reply that could not be read: \(detail)"
    }
  }
}

// MARK: - Paths

public enum WisperPaths {
  /// Environment variable that overrides the data folder (used by tests and by agents).
  public static let homeVariable = "OPEN_WISPER_HOME"

  /// Where Open Wisper keeps its files: `$OPEN_WISPER_HOME` when set,
  /// otherwise `Application Support/Open Wisper`.
  public static func defaultRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL {
    if let override = environment[homeVariable], !override.isEmpty {
      return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
    }
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("Open Wisper", isDirectory: true)
  }

}

// MARK: - App links

/// Links the apps answer to, so other tools (and the `wisper` agent tool) can
/// drive a running app: `openwisper://meetings/start?title=Standup`.
public enum WisperLink: Sendable, Equatable {
  case startMeeting(title: String?)
  case stopMeeting
  case showMeeting(Meeting.ID)
  case toggleDictation
  case showHub

  public static let scheme = "openwisper"

  public var url: URL {
    var parts = URLComponents()
    parts.scheme = WisperLink.scheme
    switch self {
    case .startMeeting(let title):
      parts.host = "meetings"
      parts.path = "/start"
      if let title, !title.isEmpty { parts.queryItems = [URLQueryItem(name: "title", value: title)] }
    case .stopMeeting:
      parts.host = "meetings"
      parts.path = "/stop"
    case .showMeeting(let id):
      parts.host = "meetings"
      parts.path = "/\(id.uuidString)"
    case .toggleDictation:
      parts.host = "dictation"
      parts.path = "/toggle"
    case .showHub:
      parts.host = "hub"
    }
    return parts.url!
  }

  public init?(_ url: URL) {
    guard url.scheme?.lowercased() == WisperLink.scheme,
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    let path = parts.path.split(separator: "/").map(String.init)
    switch (parts.host?.lowercased(), path.first) {
    case ("meetings", "start"):
      self = .startMeeting(title: parts.queryItems?.first { $0.name == "title" }?.value)
    case ("meetings", "stop"):
      self = .stopMeeting
    case ("meetings", let id?):
      guard let uuid = UUID(uuidString: id) else { return nil }
      self = .showMeeting(uuid)
    case ("dictation", "toggle"):
      self = .toggleDictation
    case ("hub", nil):
      self = .showHub
    default:
      return nil
    }
  }
}

// MARK: - Text target

/// Where dictated text goes: the app the user is typing in.
///
///   macOS -> the focused text field of the frontmost app
///   iOS   -> the clipboard / the app's own note
public protocol TextTarget: Sendable {
  /// What the user is dictating into right now.
  func context() async -> DictationContext
  /// The text currently selected in the target, if any. Used by command mode.
  func selectedText() async -> String?
  /// Types `text` at the cursor, replacing the selection.
  /// Throws `WisperError.permissionDenied(.accessibility)` when not allowed to.
  func insert(_ text: String) async throws
}

// MARK: - Permissions

public enum PermissionStatus: String, Sendable {
  case granted, denied, notDetermined
}

/// The system permissions Open Wisper needs on this platform.
@MainActor
public protocol Permissions: AnyObject {
  /// The permissions that matter on this platform, in the order to ask for them.
  var needed: [Permission] { get }
  func status(_ permission: Permission) -> PermissionStatus
  /// Shows the system prompt, or opens the right System Settings pane when
  /// the system has no prompt (or the user said no before). Returns the
  /// status afterwards; it may still be `.notDetermined` or `.denied` while
  /// the user is in System Settings, so poll `status` to see it change.
  @discardableResult
  func request(_ permission: Permission) async -> PermissionStatus
}
