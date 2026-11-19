import Foundation
import Observation
import Testing
import WisperDomain
import WisperEngine

/// How long a test waits for something that should happen right away before
/// it gives up and fails. Only reached when the engine is broken.
let patience: Duration = .seconds(10)

/// Holds a step open until the test lets it go, so a test can look at the
/// engine in the middle of its work without sleeping.
actor Gate {
  private var isOpen = false
  private var arrivals = 0
  private var waitingToPass: [CheckedContinuation<Void, Never>] = []
  private var waitingForArrival: [CheckedContinuation<Void, Never>] = []

  /// Called by the step being held. Returns once the gate is open.
  func pass() async {
    arrivals += 1
    let watchers = waitingForArrival
    waitingForArrival = []
    for watcher in watchers { watcher.resume() }
    if isOpen { return }
    await withCheckedContinuation { waitingToPass.append($0) }
  }

  /// Returns once some step has reached the gate. Fails the test, and opens
  /// the gate, when none does.
  func arrival() async {
    if arrivals > 0 { return }
    let timer = Task {
      try? await Task.sleep(for: patience)
      if !Task.isCancelled { self.giveUp() }
    }
    await withCheckedContinuation { waitingForArrival.append($0) }
    timer.cancel()
  }

  private func giveUp() {
    guard arrivals == 0 else { return }
    Issue.record("Nothing reached the gate.")
    let watchers = waitingForArrival
    waitingForArrival = []
    for watcher in watchers { watcher.resume() }
    open()
  }

  func open() {
    isOpen = true
    let held = waitingToPass
    waitingToPass = []
    for step in held { step.resume() }
  }
}

/// A value shared between a test and the closures it hands to the fakes.
final class Shared<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ value: Value) { stored = value }

  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }

  /// Changes the value and returns what it was before.
  func exchange(_ change: (inout Value) -> Void) -> Value {
    lock.withLock {
      let before = stored
      change(&stored)
      return before
    }
  }
}

/// Wakes one waiting test, once, whoever asks first.
final class Alarm: @unchecked Sendable {
  private let lock = NSLock()
  private var sleeper: CheckedContinuation<Void, Never>?
  private var rang = false

  /// Returns when `ring` is called (or right away if it already was).
  func wait() async {
    await withCheckedContinuation { continuation in
      let ringing = lock.withLock {
        if !rang { sleeper = continuation }
        return rang
      }
      if ringing { continuation.resume() }
    }
  }

  func ring() {
    let sleeper = lock.withLock {
      rang = true
      defer { self.sleeper = nil }
      return self.sleeper
    }
    sleeper?.resume()
  }
}

/// The fake capture, with a gate in front of `start`: the microphone "opens"
/// only when the test opens the gate.
struct SlowCapture: AudioCapture {
  let inner: FakeAudioCapture
  let gate: Gate
  /// Counts the times the microphone was asked to open while an earlier
  /// recording was still opening it or still held it.
  let overlaps = Shared(0)
  private let opening = Shared(0)

  func microphones() async -> [AudioDevice] { await inner.microphones() }

  func start(_ request: CaptureRequest) async throws -> any CaptureSession {
    let othersOpening = opening.exchange { $0 += 1 }
    defer { _ = opening.exchange { $0 -= 1 } }
    if othersOpening > 0 || inner.sessions.contains(where: { !$0.isEnded }) {
      _ = overlaps.exchange { $0 += 1 }
    }
    await gate.pass()
    return try await inner.start(request)
  }
}

/// A text target whose behaviour a test can change half-way.
actor ScriptedTarget: TextTarget {
  private(set) var inserted: [String] = []
  private var failure: WisperError?
  private var selection: String?
  private let current: DictationContext
  private let gate: Gate?

  init(
    context: DictationContext = DictationContext(appName: "Notes", bundleID: "com.apple.Notes"),
    selection: String? = nil,
    failure: WisperError? = nil,
    gate: Gate? = nil
  ) {
    current = context
    self.selection = selection
    self.failure = failure
    self.gate = gate
  }

  func fail(with failure: WisperError?) { self.failure = failure }
  func select(_ text: String?) { selection = text }

  func context() -> DictationContext { current }
  func selectedText() -> String? { selection }

  func insert(_ text: String) async throws {
    await gate?.pass()
    try Task.checkCancellation()
    if let failure { throw failure }
    inserted.append(text)
  }
}

/// A library that does what another one does, except where a test tells it to misbehave:
/// fail a save, or hold a read of the settings open like a slow disk.
actor ScriptedLibrary: Library {
  private let inner: any Library
  /// Says whether the save of a dictation fails, given its number (1 for the first save).
  private var failsSave: @Sendable (Int) -> Bool = { _ in false }
  private var failsSettingsWrites = false
  private var settingsGate: Gate?
  private(set) var dictationSaves = 0
  /// The user name after each settings change that was stored, in the order they arrived.
  private(set) var namesStored: [String] = []
  /// Reads of the settings that have not returned yet.
  private(set) var settingsReadsUnderWay = 0

  static let refusal = WisperError.storage("The disk is full.")

  init(_ inner: any Library = InMemoryLibrary()) { self.inner = inner }

  func failDictationSaves(_ rule: @escaping @Sendable (Int) -> Bool) { failsSave = rule }
  func failSettingsWrites(_ fails: Bool) { failsSettingsWrites = fails }
  /// From now on a read of the settings takes the value and then waits at `gate` before it returns.
  func holdSettingsReads(at gate: Gate?) { settingsGate = gate }

  /// What is stored right now, read past any hold.
  func storedName() async -> String { (try? await inner.settings().userName) ?? "" }

  func settings() async throws -> Settings {
    settingsReadsUnderWay += 1
    defer { settingsReadsUnderWay -= 1 }
    let value = try await inner.settings()
    await settingsGate?.pass()
    return value
  }

  func updateSettings(_ change: @Sendable (inout Settings) -> Void) async throws -> Settings {
    if failsSettingsWrites { throw ScriptedLibrary.refusal }
    let stored = try await inner.updateSettings(change)
    namesStored.append(stored.userName)
    return stored
  }

  func save(_ dictation: Dictation) async throws {
    dictationSaves += 1
    if failsSave(dictationSaves) { throw ScriptedLibrary.refusal }
    try await inner.save(dictation)
  }

  func words() async throws -> [DictionaryWord] { try await inner.words() }
  func save(_ word: DictionaryWord) async throws { try await inner.save(word) }
  func deleteWord(_ id: DictionaryWord.ID) async throws { try await inner.deleteWord(id) }
  func snippets() async throws -> [Snippet] { try await inner.snippets() }
  func save(_ snippet: Snippet) async throws { try await inner.save(snippet) }
  func deleteSnippet(_ id: Snippet.ID) async throws { try await inner.deleteSnippet(id) }
  func dictations(search: String?, limit: Int?) async throws -> [Dictation] {
    try await inner.dictations(search: search, limit: limit)
  }
  func deleteDictations(_ ids: Set<Dictation.ID>) async throws { try await inner.deleteDictations(ids) }
  func deleteAllDictations() async throws { try await inner.deleteAllDictations() }
  func dictationAudioDirectory() async throws -> URL { try await inner.dictationAudioDirectory() }
  func meetings(search: String?) async throws -> [Meeting] { try await inner.meetings(search: search) }
  func meeting(_ id: Meeting.ID) async throws -> Meeting? { try await inner.meeting(id) }
  func save(_ meeting: Meeting) async throws { try await inner.save(meeting) }
  func updateMeeting(
    _ id: Meeting.ID,
    _ change: @Sendable (inout Meeting) -> Void
  ) async throws -> Meeting? {
    try await inner.updateMeeting(id, change)
  }
  func deleteMeeting(_ id: Meeting.ID) async throws { try await inner.deleteMeeting(id) }
  func audioDirectory(forMeeting id: Meeting.ID) async throws -> URL {
    try await inner.audioDirectory(forMeeting: id)
  }
  nonisolated func changes() -> AsyncStream<LibraryChange> { inner.changes() }
}

/// A folder under the system's temporary folder, removed when the test ends.
final class TemporaryFolder: Sendable {
  let url: URL

  init() {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("open-wisper-engine-tests-\(UUID().uuidString)", isDirectory: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }

  /// A copy of the folder as it is right now: what the next launch would find if the app
  /// were quit at this moment.
  func snapshot() throws -> TemporaryFolder {
    let copy = TemporaryFolder()
    try FileManager.default.copyItem(at: url, to: copy.url)
    return copy
  }

  /// Names of the dictation recordings on disk.
  var audioFiles: [String] {
    let folder = url.appendingPathComponent("dictation-audio")
    return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
  }
}

/// Waits until `condition` holds. False when it never does.
@MainActor
func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + patience
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return await condition()
}

/// A language model that sends back the transcript it was given, unchanged.
/// Stands in for "the model had nothing to fix".
func echoingModel() -> FakeLanguageModel {
  FakeLanguageModel { request in transcript(in: request.user) ?? "" }
}

/// The dictated text inside a clean-up request.
func transcript(in prompt: String) -> String? {
  guard let open = prompt.range(of: "<transcript>\n"),
    let close = prompt.range(of: "\n</transcript>", range: open.upperBound..<prompt.endIndex)
  else { return nil }
  return String(prompt[open.upperBound..<close.lowerBound])
}

/// An engine wired to fakes, plus what a test needs to look at afterwards.
/// `through` puts another library in front of the in-memory one, to make it misbehave.
@MainActor
final class Rig {
  let library: InMemoryLibrary
  let capture: FakeAudioCapture
  let transcriber: FakeTranscriber
  let model: FakeLanguageModel
  let engine: DictationEngine
  /// Where the library keeps dictation audio.
  let audioFolder: URL
  /// The gated capture, when the rig was made with a `captureGate`.
  let slowCapture: SlowCapture?

  init(
    heard: String = "hello world",
    settings: Settings = Settings(),
    words: [DictionaryWord] = [],
    snippets: [Snippet] = [],
    dictations: [Dictation] = [],
    capture: FakeAudioCapture = FakeAudioCapture(),
    captureGate: Gate? = nil,
    transcriber: FakeTranscriber? = nil,
    model: FakeLanguageModel? = nil,
    target: any TextTarget = FakeTextTarget(),
    through wrap: (InMemoryLibrary) -> any Library = { $0 }
  ) async throws {
    library = InMemoryLibrary(settings: settings, words: words, snippets: snippets, dictations: dictations)
    self.capture = capture
    self.transcriber = transcriber ?? FakeTranscriber(text: heard)
    self.model = model ?? echoingModel()
    audioFolder = try await library.dictationAudioDirectory()
    slowCapture = captureGate.map { SlowCapture(inner: capture, gate: $0) }
    engine = DictationEngine(
      library: wrap(library),
      capture: slowCapture ?? capture,
      transcriber: self.transcriber,
      languageModel: self.model,
      target: target
    )
  }

  deinit {
    // The in-memory library keeps its audio in a temp folder of its own: `<scratch>/dictations`.
    try? FileManager.default.removeItem(at: audioFolder.deletingLastPathComponent())
  }

  /// One whole dictation: key down, key up.
  @discardableResult
  func dictate(_ mode: DictationMode = .dictation) async -> Dictation? {
    engine.start(mode: mode)
    return await engine.finish()
  }

  /// Returns once the microphone is open. Tests that stop without finishing
  /// wait for this, so nothing is still starting up when the test ends.
  func microphoneOpen() async {
    await until { $0.level > 0 }
  }

  /// Names of the audio files on disk right now.
  var audioFiles: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: audioFolder.path)) ?? []).sorted()
  }

  func history() async -> [Dictation] {
    await library.dictations(search: nil, limit: nil)
  }

  /// The system prompt of the only request the model got.
  var prompt: CompletionRequest? {
    model.requests.count == 1 ? model.requests[0] : nil
  }

  /// Returns once `condition` holds, woken by changes to the engine's
  /// observed state. Fails the test when it never does.
  func until(
    _ condition: (DictationEngine) -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    let deadline = ContinuousClock.now + patience
    while !condition(engine) {
      guard ContinuousClock.now < deadline else {
        Issue.record("The engine never got there. It is at \(engine.phase).", sourceLocation: sourceLocation)
        return
      }
      let alarm = Alarm()
      let timer = Task {
        try? await Task.sleep(until: deadline)
        alarm.ring()
      }
      withObservationTracking {
        _ = engine.phase
        _ = engine.level
        _ = engine.last
      } onChange: {
        alarm.ring()
      }
      await alarm.wait()
      timer.cancel()
    }
  }
}

/// The message of a `.failed` phase.
@MainActor
func failureMessage(_ engine: DictationEngine) -> String? {
  if case .failed(let message) = engine.phase { return message }
  return nil
}
