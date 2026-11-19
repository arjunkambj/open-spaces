import Foundation

// In-memory adapters for every seam. Used by tests, by the apps' demo and
// snapshot modes, and as the reference for how each seam must behave.

/// Fans one stream of values out to any number of `AsyncStream`s.
public final class Broadcaster<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

  public init() {}

  public func stream() -> AsyncStream<Value> {
    AsyncStream { continuation in
      let id = UUID()
      lock.withLock { continuations[id] = continuation }
      continuation.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.withLock { _ = self.continuations.removeValue(forKey: id) }
      }
    }
  }

  public func send(_ value: Value) {
    let targets = lock.withLock { Array(continuations.values) }
    for target in targets { target.yield(value) }
  }

  public func finish() {
    let targets = lock.withLock {
      let all = Array(continuations.values)
      continuations.removeAll()
      return all
    }
    for target in targets { target.finish() }
  }
}

public actor InMemoryLibrary: Library {
  private var storedSettings: Settings
  private var storedWords: [DictionaryWord]
  private var storedSnippets: [Snippet]
  private var storedDictations: [Dictation]
  private var storedMeetings: [Meeting]
  private let scratch: URL
  private let broadcaster = Broadcaster<LibraryChange>()

  public init(
    settings: Settings = Settings(),
    words: [DictionaryWord] = [],
    snippets: [Snippet] = [],
    dictations: [Dictation] = [],
    meetings: [Meeting] = []
  ) {
    storedSettings = settings
    storedWords = words
    storedSnippets = snippets
    storedDictations = dictations
    storedMeetings = meetings
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-wisper-memory-\(UUID().uuidString)", isDirectory: true)
  }

  public func settings() -> Settings { storedSettings }

  @discardableResult
  public func updateSettings(_ change: @Sendable (inout Settings) -> Void) -> Settings {
    change(&storedSettings)
    broadcaster.send(.settings)
    return storedSettings
  }

  public func words() -> [DictionaryWord] { storedWords.sorted { $0.createdAt > $1.createdAt } }

  public func save(_ word: DictionaryWord) {
    storedWords.removeAll { $0.id == word.id }
    storedWords.append(word)
    broadcaster.send(.words)
  }

  public func deleteWord(_ id: DictionaryWord.ID) {
    storedWords.removeAll { $0.id == id }
    broadcaster.send(.words)
  }

  public func snippets() -> [Snippet] { storedSnippets.sorted { $0.createdAt > $1.createdAt } }

  public func save(_ snippet: Snippet) {
    storedSnippets.removeAll { $0.id == snippet.id }
    storedSnippets.append(snippet)
    broadcaster.send(.snippets)
  }

  public func deleteSnippet(_ id: Snippet.ID) {
    storedSnippets.removeAll { $0.id == id }
    broadcaster.send(.snippets)
  }

  public func dictations(search: String?, limit: Int?) -> [Dictation] {
    var result = storedDictations.sorted { $0.createdAt > $1.createdAt }
    if let search, !search.isEmpty {
      result = result.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }
    if let limit { result = Array(result.prefix(limit)) }
    return result
  }

  public func save(_ dictation: Dictation) {
    storedDictations.removeAll { $0.id == dictation.id }
    storedDictations.append(dictation)
    if let maxAge = storedSettings.historyRetention.maxAge {
      let cutoff = Date().addingTimeInterval(-maxAge)
      storedDictations.removeAll { $0.createdAt < cutoff || maxAge == 0 }
    }
    broadcaster.send(.dictations)
  }

  public func deleteDictations(_ ids: Set<Dictation.ID>) {
    storedDictations.removeAll { ids.contains($0.id) }
    broadcaster.send(.dictations)
  }

  public func deleteAllDictations() {
    storedDictations.removeAll()
    broadcaster.send(.dictations)
  }

  public func dictationAudioDirectory() throws -> URL {
    try directory("dictations")
  }

  public func meetings(search: String?) -> [Meeting] {
    let all = storedMeetings.sorted { $0.startedAt > $1.startedAt }
    guard let search, !search.isEmpty else { return all }
    return all.filter { meeting in
      let haystack =
        [meeting.title, meeting.userNotes, meeting.notes?.summary ?? ""]
        + meeting.tags + meeting.segments.map(\.text)
        + (meeting.notes?.keyPoints ?? []) + (meeting.notes?.decisions ?? [])
        + (meeting.notes?.actionItems.map(\.text) ?? [])
      return haystack.contains { $0.localizedCaseInsensitiveContains(search) }
    }
  }

  public func meeting(_ id: Meeting.ID) -> Meeting? {
    storedMeetings.first { $0.id == id }
  }

  public func save(_ meeting: Meeting) {
    storedMeetings.removeAll { $0.id == meeting.id }
    storedMeetings.append(meeting)
    broadcaster.send(.meetings)
  }

  public func deleteMeeting(_ id: Meeting.ID) {
    storedMeetings.removeAll { $0.id == id }
    broadcaster.send(.meetings)
  }

  public func audioDirectory(forMeeting id: Meeting.ID) throws -> URL {
    try directory("meetings/\(id.uuidString)")
  }

  public nonisolated func changes() -> AsyncStream<LibraryChange> {
    broadcaster.stream()
  }

  private func directory(_ path: String) throws -> URL {
    let url = scratch.appendingPathComponent(path, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

public actor InMemorySecretStore: SecretStore {
  private var key: String?

  public init(apiKey: String? = nil) { key = apiKey }

  public func apiKey() -> String? { key }

  public func setAPIKey(_ key: String?) {
    self.key = (key?.isEmpty ?? true) ? nil : key
  }
}

/// Answers every transcription with `reply`, and remembers what it was asked.
public final class FakeTranscriber: Transcriber, @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [TranscriptionRequest] = []
  private let reply: @Sendable (TranscriptionRequest) async throws -> Transcript

  public init(reply: @escaping @Sendable (TranscriptionRequest) async throws -> Transcript) {
    self.reply = reply
  }

  public convenience init(text: String) {
    self.init { _ in Transcript(text: text) }
  }

  public var requests: [TranscriptionRequest] { lock.withLock { seen } }

  public func transcribe(_ request: TranscriptionRequest) async throws -> Transcript {
    lock.withLock { seen.append(request) }
    return try await reply(request)
  }
}

/// Answers every prompt with `reply`, and remembers what it was asked.
public final class FakeLanguageModel: LanguageModel, @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [CompletionRequest] = []
  private let reply: @Sendable (CompletionRequest) async throws -> String

  public init(reply: @escaping @Sendable (CompletionRequest) async throws -> String) {
    self.reply = reply
  }

  public convenience init(text: String) {
    self.init { _ in text }
  }

  public var requests: [CompletionRequest] { lock.withLock { seen } }

  public func complete(_ request: CompletionRequest) async throws -> String {
    lock.withLock { seen.append(request) }
    return try await reply(request)
  }
}

/// A capture that records nothing real. Each `emit` (or `stop`) writes a tiny
/// placeholder file per track and sends it as a chunk.
public final class FakeAudioCapture: AudioCapture, @unchecked Sendable {
  private let lock = NSLock()
  private var started: [CaptureRequest] = []
  private var active: [Session] = []
  public let devices: [AudioDevice]
  /// When set, `start` throws it.
  public let failure: WisperError?
  /// Length reported for the audio flushed by `stop()`.
  public let stopDuration: TimeInterval

  public init(
    devices: [AudioDevice] = [AudioDevice(id: "built-in", name: "MacBook Pro Microphone", isDefault: true)],
    failure: WisperError? = nil,
    stopDuration: TimeInterval = 3
  ) {
    self.devices = devices
    self.failure = failure
    self.stopDuration = stopDuration
  }

  public var requests: [CaptureRequest] { lock.withLock { started } }
  /// The sessions started so far, oldest first.
  public var sessions: [Session] { lock.withLock { active } }

  public func microphones() async -> [AudioDevice] { devices }

  public func start(_ request: CaptureRequest) async throws -> any CaptureSession {
    if let failure { throw failure }
    let session = Session(request: request, stopDuration: stopDuration)
    lock.withLock {
      started.append(request)
      active.append(session)
    }
    return session
  }

  public final class Session: CaptureSession, @unchecked Sendable {
    public let levels: AsyncStream<Float>
    public let chunks: AsyncStream<AudioChunk>
    private let levelContinuation: AsyncStream<Float>.Continuation
    private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    private let request: CaptureRequest
    private let stopDuration: TimeInterval
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    private var index = 0
    private var ended = false

    init(request: CaptureRequest, stopDuration: TimeInterval) {
      self.request = request
      self.stopDuration = stopDuration
      (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self)
      (chunks, chunkContinuation) = AsyncStream.makeStream(of: AudioChunk.self)
      levelContinuation.yield(0.4)
    }

    public var isEnded: Bool { lock.withLock { ended } }

    /// Sends a loudness value to `levels`.
    public func setLevel(_ level: Float) { levelContinuation.yield(level) }

    /// Finishes a chunk of `duration` seconds on every requested track.
    public func emit(duration: TimeInterval) {
      let (start, number): (TimeInterval, Int) = lock.withLock {
        let current = (offset, index)
        offset += duration
        index += 1
        return current
      }
      for track in AudioTrack.allCases where request.tracks.contains(track) {
        let url = request.directory.appendingPathComponent("\(track.rawValue)-\(number).m4a")
        try? Data("fake audio".utf8).write(to: url)
        chunkContinuation.yield(AudioChunk(track: track, url: url, offset: start, duration: duration))
      }
    }

    public func stop() async {
      guard !end() else { return }
      emit(duration: stopDuration)
      levelContinuation.finish()
      chunkContinuation.finish()
    }

    public func cancel() async {
      guard !end() else { return }
      levelContinuation.finish()
      chunkContinuation.finish()
    }

    /// Marks the session ended. Returns whether it already was.
    private func end() -> Bool {
      lock.withLock {
        let was = ended
        ended = true
        return was
      }
    }
  }
}

/// Collects inserted text instead of typing it anywhere.
public actor FakeTextTarget: TextTarget {
  public private(set) var inserted: [String] = []
  private var current: DictationContext
  private var selection: String?
  private var failure: WisperError?

  public init(
    context: DictationContext = DictationContext(appName: "Notes", bundleID: "com.apple.Notes"),
    selection: String? = nil,
    failure: WisperError? = nil
  ) {
    current = context
    self.selection = selection
    self.failure = failure
  }

  public func context() -> DictationContext { current }
  public func selectedText() -> String? { selection }

  public func insert(_ text: String) throws {
    if let failure { throw failure }
    inserted.append(text)
  }
}

@MainActor
public final class FakePermissions: Permissions {
  public var statuses: [Permission: PermissionStatus]
  public let needed: [Permission]

  public init(
    needed: [Permission] = Permission.allCases,
    statuses: [Permission: PermissionStatus] = [:]
  ) {
    self.needed = needed
    self.statuses = statuses
  }

  public func status(_ permission: Permission) -> PermissionStatus {
    statuses[permission] ?? .notDetermined
  }

  @discardableResult
  public func request(_ permission: Permission) async -> PermissionStatus {
    statuses[permission] = .granted
    return .granted
  }
}

/// Made-up content for demos, snapshots and tests. Nothing here is real user data.
public enum SampleData {
  public static func library(now: Date = Date(), onboarded: Bool = true) -> InMemoryLibrary {
    InMemoryLibrary(
      settings: Settings(
        userName: "Alex",
        onboardedAt: onboarded ? now.addingTimeInterval(-20 * 86_400) : nil
      ),
      words: words(now: now),
      snippets: snippets(now: now),
      dictations: dictations(now: now),
      meetings: meetings(now: now)
    )
  }

  public static func words(now: Date = Date()) -> [DictionaryWord] {
    [
      DictionaryWord(
        text: "Kubernetes",
        replaces: "cooper netties",
        createdAt: now.addingTimeInterval(-3_600)
      ),
      DictionaryWord(text: "Open Wisper", createdAt: now.addingTimeInterval(-7_200)),
      DictionaryWord(text: "Priya Raman", createdAt: now.addingTimeInterval(-86_400)),
      DictionaryWord(
        text: "PostgreSQL",
        replaces: "post gres",
        createdAt: now.addingTimeInterval(-2 * 86_400)
      ),
    ]
  }

  public static func snippets(now: Date = Date()) -> [Snippet] {
    [
      Snippet(
        trigger: "my calendar link",
        expansion: "https://cal.example.com/alex",
        createdAt: now.addingTimeInterval(-3_600)
      ),
      Snippet(
        trigger: "intro email",
        expansion: "Hi! Great to meet you. I'd love to find 30 minutes to chat this week.",
        createdAt: now.addingTimeInterval(-86_400)
      ),
    ]
  }

  public static func dictations(now: Date = Date()) -> [Dictation] {
    let entries: [(TimeInterval, String, String, TimeInterval)] = [
      (-600, "Slack", "Sounds good, I'll take a look at the pull request after lunch and leave comments.", 6),
      (-4_200, "Mail", "Hi Priya, thanks for the update. Could we move the review to Thursday at 3 pm?", 7),
      (
        -9_000, "Notes",
        "Ideas for the launch post: start with the problem, show the demo, end with the roadmap.", 8
      ),
      (-86_400 - 1_800, "Linear", "Fix the flaky upload test and add a retry around the storage call.", 5),
      (-86_400 - 7_200, "Messages", "running ten minutes late, order me a flat white please", 4),
      (
        -2 * 86_400 - 3_000, "Cursor",
        "Rename the handler to processUpload and add a doc comment that explains the retry.", 7
      ),
    ]
    return entries.map { offset, app, text, duration in
      Dictation(
        createdAt: now.addingTimeInterval(offset),
        rawText: text,
        text: text,
        duration: duration,
        appName: app
      )
    }
  }

  public static func meetings(now: Date = Date()) -> [Meeting] {
    let start = now.addingTimeInterval(-26 * 3_600)
    let standup = Meeting(
      title: "Weekly product sync",
      startedAt: start,
      endedAt: start.addingTimeInterval(1_860),
      status: .ready,
      segments: [
        TranscriptSegment(
          speaker: .me,
          start: 2,
          end: 9,
          text: "Thanks for joining. Let's start with the launch date."
        ),
        TranscriptSegment(
          speaker: .others,
          start: 10,
          end: 21,
          text: "We're on track for the 14th. The only open risk is the billing migration."
        ),
        TranscriptSegment(
          speaker: .me,
          start: 22,
          end: 30,
          text: "Okay. I'll check in with Sam about billing today."
        ),
        TranscriptSegment(
          speaker: .others,
          start: 31,
          end: 44,
          text: "I can have the onboarding copy ready by Wednesday so design can review it."
        ),
      ],
      notes: MeetingNotes(
        summary:
          "The team confirmed the launch is on track for the 14th. Billing migration is the one open risk. "
          + "Onboarding copy will be ready for design review mid-week.",
        keyPoints: [
          "Launch stays on the 14th", "Billing migration is the main risk", "Onboarding copy due Wednesday",
        ],
        decisions: ["Keep the launch date"],
        actionItems: [
          ActionItem(text: "Check in with Sam about the billing migration", owner: "Alex"),
          ActionItem(text: "Send onboarding copy to design", owner: "Jordan", done: true),
        ]
      ),
      userNotes: "Follow up on pricing page next week.",
      tags: ["product"]
    )
    let interviewStart = now.addingTimeInterval(-3 * 86_400)
    let interview = Meeting(
      title: "Customer call with Northwind",
      startedAt: interviewStart,
      endedAt: interviewStart.addingTimeInterval(2_700),
      status: .ready,
      segments: [
        TranscriptSegment(
          speaker: .others,
          start: 4,
          end: 15,
          text: "Our team mostly dictates notes after site visits."
        ),
        TranscriptSegment(speaker: .me, start: 16, end: 22, text: "How do those notes get shared today?"),
      ],
      notes: MeetingNotes(
        summary: "Northwind's field team dictates notes after site visits and shares them by email.",
        keyPoints: ["Notes are dictated on phones", "Sharing happens over email"],
        actionItems: [ActionItem(text: "Send a summary and pricing", owner: "Alex")]
      ),
      tags: ["customer"]
    )
    let untitledStart = now.addingTimeInterval(-6 * 86_400)
    let short = Meeting(
      title: "1:1 with Jordan",
      startedAt: untitledStart,
      endedAt: untitledStart.addingTimeInterval(1_500),
      status: .ready,
      segments: [TranscriptSegment(speaker: .me, start: 1, end: 6, text: "How is the week going?")]
    )
    return [standup, interview, short]
  }
}
