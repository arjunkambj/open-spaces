import Foundation
import Observation
import Testing
import WisperDomain

@testable import WisperEngine

/// A meeting engine wired to the in-memory fakes.
@MainActor
final class MeetingRig {
  let library: InMemoryLibrary
  let capture: FakeAudioCapture
  let transcriber: FakeTranscriber
  let model: FakeLanguageModel
  let engine: MeetingEngine

  /// Numbers that keep tests fast: no waiting between tries, every change saved.
  static func tuning(notesCharacterLimit: Int = 60_000) -> MeetingEngine.Tuning {
    MeetingEngine.Tuning(
      attempts: 2,
      retryDelay: .zero,
      liveSaveInterval: .zero,
      notesCharacterLimit: notesCharacterLimit
    )
  }

  init(
    library: InMemoryLibrary? = nil,
    settings: Settings = Settings(userName: "Alex"),
    words: [DictionaryWord] = [],
    capture: FakeAudioCapture = FakeAudioCapture(),
    startingCapture: (any AudioCapture)? = nil,
    transcriber: FakeTranscriber = MeetingRig.hears([:]),
    model: FakeLanguageModel = FakeLanguageModel(text: MeetingRig.notesJSON()),
    tuning: MeetingEngine.Tuning = MeetingRig.tuning()
  ) {
    self.library = library ?? InMemoryLibrary(settings: settings, words: words)
    self.capture = capture
    self.transcriber = transcriber
    self.model = model
    engine = MeetingEngine(
      library: self.library,
      capture: startingCapture ?? capture,
      transcriber: transcriber,
      languageModel: model,
      tuning: tuning
    )
  }

  /// The capture session of the recording in progress.
  var session: FakeAudioCapture.Session {
    get throws { try #require(capture.sessions.last) }
  }

  func meeting(_ id: Meeting.ID) async throws -> Meeting {
    try #require(await library.meeting(id))
  }

  /// Waits until the stored meeting satisfies `condition`.
  func meeting(_ id: Meeting.ID, when condition: (Meeting) -> Bool) async throws -> Meeting {
    let changes = library.changes()
    if let meeting = await library.meeting(id), condition(meeting) { return meeting }
    for await _ in changes {
      if let meeting = await library.meeting(id), condition(meeting) { return meeting }
    }
    throw WisperError.notFound("The meeting")
  }

  /// Waits until nothing is being processed in the background, then returns the stored meeting.
  func finished(_ id: Meeting.ID) async throws -> Meeting {
    await until { self.engine.processing.isEmpty }
    return try await meeting(id)
  }

  /// Names of the files in the meeting's audio folder.
  func audioFiles(_ id: Meeting.ID) async throws -> [String] {
    let directory = try await library.audioDirectory(forMeeting: id)
    return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  /// Waits until `condition` holds for the engine's observable state.
  func until(_ condition: @MainActor () -> Bool) async {
    while true {
      let (changed, signal) = AsyncStream.makeStream(of: Void.self)
      let met = withObservationTracking {
        condition()
      } onChange: {
        signal.yield()
        signal.finish()
      }
      if met { return }
      for await _ in changed { break }
    }
  }

  /// A transcriber that hears `lines[name]` in the audio file called `name`, e.g.
  /// "microphone-0" or "system-1", and nothing in any other file.
  nonisolated static func hears(_ lines: [String: String]) -> FakeTranscriber {
    FakeTranscriber { request in Transcript(text: lines[MeetingRig.name(of: request)] ?? "") }
  }

  /// The audio file's name without its extension: the track and the chunk number.
  nonisolated static func name(of request: TranscriptionRequest) -> String {
    request.audio.deletingPathExtension().lastPathComponent
  }

  /// Notes the way the language model sends them back.
  nonisolated static func notesJSON(
    title: String = "Launch planning",
    summary: String = "The team talked about the launch.",
    keyPoints: [String] = ["Launch is on track"],
    decisions: [String] = ["Ship on Friday"],
    actionItems: [(text: String, owner: String?)] = [("Check with Sam about billing", "Alex")]
  ) -> String {
    let object: [String: Any] = [
      "title": title,
      "summary": summary,
      "keyPoints": keyPoints,
      "decisions": decisions,
      "actionItems": actionItems.map { ["text": $0.text, "owner": $0.owner ?? NSNull()] as [String: Any] },
    ]
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }
}

/// Holds callers back until it is opened.
final class MeetingGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { continuation in
      let goes = lock.withLock {
        if !isOpen { waiters.append(continuation) }
        return isOpen
      }
      if goes { continuation.resume() }
    }
  }

  func open() {
    let waiting = lock.withLock {
      isOpen = true
      defer { waiters = [] }
      return waiters
    }
    for waiter in waiting { waiter.resume() }
  }
}

/// A switch tests flip while fakes are running.
final class MeetingSwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool

  init(_ value: Bool) { self.value = value }

  var isOn: Bool { lock.withLock { value } }
  func set(_ on: Bool) { lock.withLock { value = on } }
}

/// A capture that refuses some requests and passes the rest on to a fake.
struct MeetingPickyCapture: AudioCapture {
  let inner: FakeAudioCapture
  let refusal: @Sendable (CaptureRequest) -> WisperError?

  func microphones() async -> [AudioDevice] { await inner.microphones() }

  func start(_ request: CaptureRequest) async throws -> any CaptureSession {
    if let error = refusal(request) { throw error }
    return try await inner.start(request)
  }
}
