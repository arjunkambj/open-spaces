import Foundation

// The seams of Spaces. Each protocol here has a real adapter in another
// package. `Fakes.swift` holds the in-memory ones that demo mode and the snapshots use.
//
//   Library        -> SpacesStore.FileLibrary          (files on disk)
//   SecretStore    -> SpacesStore.FileSecretStore      (a private file)
//   Transcriber    -> SpacesAI.OpenAITranscriber       (OpenAI audio API)
//   LiveTranscriber -> SpacesAI.OpenAILiveTranscriber  (OpenAI realtime API)
//   LanguageModel  -> SpacesAI.OpenAILanguageModel     (OpenAI chat API)
//                  -> SpacesAI.AnthropicLanguageModel  (Anthropic messages API, Claude models)
//   AudioCapture   -> SpacesAudio.SystemAudioCapture   (AVFoundation / Core Audio)
//   TextTarget     -> SpacesMac.MacTextTarget          (the app you are typing in)
//   Permissions    -> SpacesMac.MacPermissions         (system permission prompts)

// MARK: - Library

/// Everything Spaces stores, all of it on this device.
///
/// One instance is shared per process. Every write is durable when the call
/// returns. Other processes (the `spaces` agent tool) may write to the same
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
  /// Inserts or replaces by `id`. To change part of a stored meeting, use
  /// `updateMeeting`, so another writer's edit is never overwritten.
  func save(_ meeting: Meeting) async throws
  /// Applies `change` to the stored meeting in one step and returns the
  /// result: no other writer, in this process or another, can slip in between
  /// the read and the write. Returns `nil`, and saves nothing, when the
  /// meeting does not exist (it is never brought back after a delete).
  @discardableResult
  func updateMeeting(
    _ id: Meeting.ID,
    _ change: @Sendable (inout Meeting) -> Void
  ) async throws -> Meeting?
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

/// Holds the user's API keys. Never written into the library files themselves.
///
/// Each key belongs to one server: the host it was saved for (see `APIServer.host`), such as
/// the OpenAI server for speech and Anthropic for Claude. A key is handed out only for its own
/// host, so a change to the server address in the settings file can never send a key
/// somewhere its owner did not choose.
public protocol SecretStore: Sendable {
  /// The key saved for `host`. `nil` when none is saved for that server. Host names are
  /// compared without regard to case.
  func apiKey(for host: String) async throws -> String?
  /// Saves `key` as the key for `host`, replacing the key saved for that host before. Keys
  /// of other hosts stay. Pass `nil` (or an empty key) to remove the key of `host`.
  func setAPIKey(_ key: String?, host: String) async throws
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
  /// Throws `SpacesError`. Returns an empty `text` when the audio holds no speech.
  func transcribe(_ request: TranscriptionRequest) async throws -> Transcript
  /// Gets ready for a `transcribe` that will follow soon, so it starts without delay: an
  /// adapter that talks to a server opens (or checks) its connection. Call it when recording
  /// starts, and again now and then during a long recording. It sends no audio and no key,
  /// never throws, and may be called at any time, any number of times. Does nothing by default.
  func prepare() async
}

extension Transcriber {
  public func prepare() async {}
}

// MARK: - Transcription while speaking

public struct LiveTranscriptionRequest: Sendable {
  public var model: String
  /// ISO 639-1 code, or `nil` to auto-detect.
  public var language: String?
  /// Words the transcriber should prefer (names, jargon).
  public var vocabulary: [String]

  public init(model: String, language: String? = nil, vocabulary: [String] = []) {
    self.model = model
    self.language = language
    self.vocabulary = vocabulary
  }
}

/// One recording being turned into text while it is still being made.
///
/// Hand over the sound with `send` as it is captured, then call `finish` once for the text.
/// A session that will not be finished must be cancelled.
public protocol LiveTranscription: Sendable {
  /// The text heard so far. Each value replaces the one before. Ends when the session ends.
  /// May stay empty: not every transcriber reports before the end.
  var partials: AsyncStream<String> { get }
  /// Hands over the next run of sound, in order. Returns at once: the sending is queued.
  func send(_ frames: AudioFrames)
  /// Says the sound is over and returns the text of all of it. Returns an empty `text` when
  /// no speech was heard. Throws `SpacesError` when the session failed at any point, also
  /// before this call; the text is then incomplete and must not be used.
  func finish() async throws -> Transcript
  /// Ends the session at once. Nothing more is sent, and a `finish` under way throws.
  func cancel()
}

/// Turns sound into text while it is being recorded.
///
/// This is an extra: the recording is always written to a file as well, and a `Transcriber`
/// can turn that file into text whenever a live session cannot be opened or fails.
public protocol LiveTranscriber: Sendable {
  /// Opens a session that is ready to take sound. Throws `SpacesError` when that is not
  /// possible: the server or the model does not offer it, or it cannot be reached.
  func open(_ request: LiveTranscriptionRequest) async throws -> any LiveTranscription
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
  /// Throws `SpacesError`.
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
  /// Whether the sound is also handed over while it is recorded, in `CaptureSession.frames`.
  /// Only for a capture that writes one file (`chunkSeconds == nil`).
  public var liveFrames: Bool

  public init(
    tracks: Set<AudioTrack> = [.microphone],
    microphoneID: String? = nil,
    directory: URL,
    chunkSeconds: TimeInterval? = nil,
    liveFrames: Bool = false
  ) {
    self.tracks = tracks
    self.microphoneID = microphoneID
    self.directory = directory
    self.chunkSeconds = chunkSeconds
    self.liveFrames = liveFrames
  }
}

/// A run of sound from a capture in progress: one channel, samples from -1 to 1.
public struct AudioFrames: Sendable, Equatable {
  public var samples: [Float]
  /// Samples per second.
  public var sampleRate: Double

  public init(samples: [Float], sampleRate: Double) {
    self.samples = samples
    self.sampleRate = sampleRate
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
  /// The sound of the microphone track as it is recorded, when the request asked for
  /// `liveFrames`: the very samples that go into the file, in order, a fraction of a second
  /// at a time. Ends after `stop()` has handed over the last of it, or right away after
  /// `cancel()`. Iterate it once. Ends at once when the request did not ask for it.
  ///
  /// It never holds the recording up: a reader that falls minutes behind misses frames. So
  /// before trusting what was read as the whole recording, compare the number of samples
  /// with the `duration` of the file.
  var frames: AsyncStream<AudioFrames> { get }
  /// Stops recording and flushes the remaining audio into `chunks`.
  func stop() async
  /// Stops recording and deletes everything not yet emitted.
  func cancel() async
}

/// Records audio into files.
public protocol AudioCapture: Sendable {
  /// Input devices that can be used for the microphone track.
  func microphones() async -> [AudioDevice]
  /// Starts recording. Throws `SpacesError.permissionDenied` when access to
  /// the microphone or system audio has not been granted, and
  /// `SpacesError.captureFailed` for anything else.
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

/// The errors Spaces shows to people. Every seam throws these.
///
/// `errorDescription` words them for OpenAI (or for Anthropic, inside `.anthropic`). When the person uses a server
/// of their own, show `message(server:)` instead, which names that server.
public enum SpacesError: Error, Sendable, Equatable, LocalizedError {
  case missingAPIKey
  case invalidAPIKey
  case rateLimited
  /// The request never reached the server (offline, timeout).
  case network(String)
  /// The server answered with an error.
  case server(status: Int, message: String)
  case noSpeech
  case permissionDenied(Permission)
  case captureFailed(String)
  case notFound(String)
  case storage(String)
  case invalidResponse(String)
  /// `Settings.apiBaseURL` is set, but is not a usable `http://` or `https://` address.
  case invalidServerAddress
  /// The language model answered a command with far more text than could be meant.
  case replyTooLong
  /// A request to Anthropic, for a Claude model, failed with this error. Worded for Anthropic.
  indirect case anthropic(SpacesError)

  public var errorDescription: String? {
    switch self {
    case .missingAPIKey: "Add your OpenAI API key in Settings to start dictating."
    case .invalidAPIKey: "OpenAI did not accept your API key. Check it in Settings."
    case .rateLimited: "OpenAI is limiting requests for your key right now. Try again in a moment."
    case .network(SpacesError.noAnswerDetail):
      "OpenAI did not answer in time, even on a second try. Try again in a moment."
    case .network(let detail): "Could not reach OpenAI. Check your internet connection. (\(detail))"
    case .server(let status, let message): "OpenAI returned an error (\(status)): \(message)"
    case .noSpeech: "No speech was heard."
    case .permissionDenied(let permission):
      "\(permission.label) access is needed. Turn it on in System Settings."
    case .captureFailed(let detail): "Recording failed: \(detail)"
    case .notFound(let what): "\(what) was not found."
    case .storage(let detail): "Could not read or save your data: \(detail)"
    case .invalidResponse(let detail): "OpenAI sent a reply that could not be read: \(detail)"
    case .invalidServerAddress: "The custom server address in Settings is not a valid web address."
    case .replyTooLong: "The reply was far longer than expected, so it was not typed. Try the command again."
    case .anthropic(let error): SpacesError.anthropicMessage(error)
    }
  }

  private static func anthropicMessage(_ error: SpacesError) -> String? {
    switch error {
    case .missingAPIKey: "Add your Anthropic API key in Settings to use a Claude model."
    case .invalidAPIKey: "Anthropic did not accept your API key. Check it in Settings."
    case .rateLimited: "Anthropic is limiting requests for your key right now. Try again in a moment."
    case .network(SpacesError.noAnswerDetail):
      "Anthropic did not answer in time, even on a second try. Try again in a moment."
    case .network(let detail): "Could not reach Anthropic. Check your internet connection. (\(detail))"
    case .server(let status, let message): "Anthropic returned an error (\(status)): \(message)"
    case .invalidResponse(let detail): "Anthropic sent a reply that could not be read: \(detail)"
    default: error.errorDescription
    }
  }
}

extension SpacesError {
  /// The request went out, twice, and no answer came back in the time allowed. Not the same
  /// as being offline: the connection may be fine and the server slow or stuck.
  public static let noAnswer = SpacesError.network(noAnswerDetail)

  static let noAnswerDetail = "no answer in time"
}

// MARK: - Paths

public enum SpacesPaths {
  /// Environment variable that overrides the data folder.
  public static let homeVariable = "SPACES_HOME"

  /// Where Spaces keeps its files: `$SPACES_HOME` when set,
  /// otherwise `Application Support/Spaces`.
  public static func defaultRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let override = environment[homeVariable], !override.isEmpty {
      return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Spaces", isDirectory: true)
  }
}

// MARK: - App links

/// Links the apps answer to, so other tools (and the `spaces` agent tool) can
/// drive a running app: `openspaces://meetings/start?title=Standup`.
public enum SpacesLink: Sendable, Equatable {
  case startMeeting(title: String?)
  case stopMeeting
  case showMeeting(Meeting.ID)
  case toggleDictation
  case showHub

  public static let scheme = "openspaces"

  /// Whether this link makes the app start listening or cut a recording short.
  /// The app acts on such a link without asking only when it carries a valid
  /// `LinkTicket`; any other sender (a web page, a document) gets a question first.
  public var needsTrust: Bool {
    switch self {
    case .startMeeting, .stopMeeting, .toggleDictation: true
    case .showMeeting, .showHub: false
    }
  }

  /// The link with a ticket attached. See `LinkTicket`.
  public func url(ticket: String?) -> URL {
    guard let ticket, !ticket.isEmpty else { return url }
    var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "ticket", value: ticket)]
    return parts.url!
  }

  /// The ticket a link carries, if any.
  public static func ticket(in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?.first { $0.name == "ticket" }?.value
  }

  public var url: URL {
    var parts = URLComponents()
    parts.scheme = SpacesLink.scheme
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
    guard url.scheme?.lowercased() == SpacesLink.scheme,
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    let path = parts.path.split(separator: "/").map(String.init)
    switch (parts.host?.lowercased(), path.first) {
    case ("meetings", "start"):
      // A title is a short label. Anything longer is cut, and line breaks are dropped.
      let title = parts.queryItems?.first { $0.name == "title" }?.value
      self = .startMeeting(title: title.map(SpacesLink.tidyTitle).flatMap { $0.isEmpty ? nil : $0 })
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
  /// Throws `SpacesError.permissionDenied(.accessibility)` when not allowed to.
  func insert(_ text: String) async throws
}

// MARK: - Permissions

public enum PermissionStatus: String, Sendable {
  case granted, denied, notDetermined
}

/// The system permissions Spaces needs on this platform.
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

extension SpacesLink {
  /// One line, at most 120 characters.
  static func tidyTitle(_ title: String) -> String {
    let oneLine = title.split(whereSeparator: \.isNewline).joined(separator: " ")
    return String(oneLine.trimmingCharacters(in: .whitespaces).prefix(120))
  }
}

/// Proof that a link was sent by something that can already write the data
/// folder (the bundled `spaces` tool, the keyboard extension), and not by a
/// web page or a document.
///
/// The sender calls `issue` and puts the ticket in the link
/// (`SpacesLink.url(ticket:)`). The app calls `redeem` with the ticket from
/// the link it received. A ticket works once, and only for a minute.
public enum LinkTicket {
  /// How long a ticket stays valid.
  public static let lifetime: TimeInterval = 60

  /// Writes a fresh ticket into the data folder and returns it.
  public static func issue(in root: URL = SpacesPaths.defaultRoot()) throws -> String {
    let folder = self.folder(in: root)
    do {
      try FileManager.default.createDirectory(
        at: folder,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      sweep(folder)
      let ticket = UUID().uuidString + UUID().uuidString
      let file = folder.appendingPathComponent(ticket)
      guard
        FileManager.default.createFile(
          atPath: file.path,
          contents: Data(),
          attributes: [.posixPermissions: 0o600]
        )
      else { throw SpacesError.storage("The data folder could not be written.") }
      return ticket
    } catch let error as SpacesError {
      throw error
    } catch {
      throw SpacesError.storage(error.localizedDescription)
    }
  }

  /// Whether `ticket` was issued in this data folder within the last minute.
  /// A ticket is used up by this call.
  public static func redeem(_ ticket: String?, in root: URL = SpacesPaths.defaultRoot()) -> Bool {
    // A ticket is a bare name made of letters, digits and dashes: never a path.
    guard let ticket, (32...128).contains(ticket.count),
      ticket.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    else { return false }
    let file = folder(in: root).appendingPathComponent(ticket)
    guard let made = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.creationDate] as? Date
    else { return false }
    guard (try? FileManager.default.removeItem(at: file)) != nil else { return false }
    let age = Date().timeIntervalSince(made)
    return age >= -5 && age <= lifetime
  }

  private static func folder(in root: URL) -> URL {
    root.appendingPathComponent(".tickets", isDirectory: true)
  }

  /// Removes tickets nobody used.
  private static func sweep(_ folder: URL) {
    let old = Date().addingTimeInterval(-lifetime * 2)
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.creationDateKey]
      )) ?? []
    for file in files {
      let made = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
      if made < old { try? FileManager.default.removeItem(at: file) }
    }
  }
}
