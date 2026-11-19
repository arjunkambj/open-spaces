import AudioToolbox
import Foundation
import Observation
import Testing
import WisperDomain
import WisperStore

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
  static func tuning(
    notesCharacterLimit: Int = 60_000,
    recordsSystemAudio: Bool = true
  ) -> MeetingEngine.Tuning {
    MeetingEngine.Tuning(
      attempts: 2,
      retryDelay: .zero,
      liveSaveInterval: .zero,
      notesCharacterLimit: notesCharacterLimit,
      recordsSystemAudio: recordsSystemAudio
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
  func until(_ condition: @MainActor () -> Bool) async { await meetingUntil(condition) }

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

/// Waits until `condition` holds for state that can be observed.
@MainActor
func meetingUntil(_ condition: @MainActor () -> Bool) async {
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

/// A meeting engine on the real file library, in a folder of its own that goes away with the rig.
@MainActor
final class MeetingDiskRig {
  let root: URL
  let library: FileLibrary
  let capture = FakeAudioCapture()
  let transcriber: FakeTranscriber
  let model: FakeLanguageModel
  let engine: MeetingEngine

  init(
    keepAudio: Bool = true,
    transcriber: FakeTranscriber = MeetingDiskRig.hearsTheFileName(),
    model: FakeLanguageModel = FakeLanguageModel(text: MeetingRig.notesJSON())
  ) async throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("wisper-meeting-tests-\(UUID().uuidString)", isDirectory: true)
    library = FileLibrary(root: root)
    try await library.updateSettings { $0.meetings.keepAudio = keepAudio }
    self.transcriber = transcriber
    self.model = model
    engine = MeetingEngine(
      library: library,
      capture: capture,
      transcriber: transcriber,
      languageModel: model,
      tuning: MeetingRig.tuning()
    )
  }

  deinit { try? FileManager.default.removeItem(at: root) }

  /// A transcriber that hears, in every file, the name of that file.
  nonisolated static func hearsTheFileName() -> FakeTranscriber {
    FakeTranscriber { request in Transcript(text: "Said in \(request.audio.lastPathComponent).") }
  }

  func folder(_ id: Meeting.ID) -> URL { root.appendingPathComponent("meetings/\(id.uuidString)") }
  func audioFolder(_ id: Meeting.ID) -> URL { folder(id).appendingPathComponent("audio") }

  /// Names of the files in a folder, or nothing when the folder is not there.
  func files(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
  }

  func meeting(_ id: Meeting.ID) async throws -> Meeting {
    try #require(try await library.meeting(id))
  }

  /// Waits until nothing is being processed in the background, then returns the stored meeting.
  func finished(_ id: Meeting.ID) async throws -> Meeting {
    await meetingUntil { self.engine.processing.isEmpty }
    return try await meeting(id)
  }

  /// Saves a meeting the way a crash leaves it: still marked as being recorded. Returns its
  /// audio folder, ready to be filled.
  func interruptedMeeting(title: String = "Board call") async throws -> (Meeting, URL) {
    let meeting = Meeting(title: title, startedAt: Date(timeIntervalSinceNow: -3_600), status: .recording)
    try await library.save(meeting)
    return (meeting, try await library.audioDirectory(forMeeting: meeting.id))
  }

  /// What the transcriber was sent, as file names, in alphabetical order.
  var transcribed: [String] { transcriber.requests.map(\.audio.lastPathComponent).sorted() }

  /// The engine's record of the audio, as it is on disk.
  func manifest(_ id: Meeting.ID) -> MeetingManifest? { MeetingManifest.read(from: audioFolder(id)) }
}

/// Real audio files for tests, made without a microphone.
enum MeetingAudio {
  private static let sampleRate = 16_000.0

  private static func tone(_ seconds: Double) -> [Float] {
    (0..<Int(seconds * sampleRate)).map { 0.1 * sin(Float($0) * 2 * .pi * 440 / Float(sampleRate)) }
  }

  /// Writes `seconds` of a tone as AAC in an `.m4a`, as capture does for a finished file.
  static func writeM4A(_ seconds: Double, to url: URL) throws {
    try writeM4A(seconds, to: url, whileOpen: {})
  }

  /// Writes an `.m4a` the way it is on disk when the app is killed while the file is being
  /// written: the sound so far, and no index to find it by.
  static func writeUnfinishedM4A(to url: URL) throws {
    let whole = url.deletingLastPathComponent().appendingPathComponent("whole-\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: whole) }
    // A process that is killed leaves exactly the bytes that are in the file at that moment.
    try writeM4A(8, to: whole) { try FileManager.default.copyItem(at: whole, to: url) }
  }

  /// Writes a finished `.m4a` and then cuts the file off half-way, as a copy that was
  /// interrupted or a damaged disk would.
  static func writeM4ACutInHalf(_ seconds: Double, to url: URL) throws {
    try writeM4A(seconds, to: url)
    let data = try Data(contentsOf: url)
    try data.prefix(data.count / 2).write(to: url)
  }

  private static func writeM4A(_ seconds: Double, to url: URL, whileOpen: () throws -> Void) throws {
    var format = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatMPEG4AAC,
      mFormatFlags: 0,
      mBytesPerPacket: 0,
      mFramesPerPacket: 1_024,
      mBytesPerFrame: 0,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 0,
      mReserved: 0
    )
    var file: ExtAudioFileRef?
    let flags = AudioFileFlags.eraseFile.rawValue
    guard ExtAudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &format, nil, flags, &file) == noErr,
      let file
    else { throw WisperError.storage("The test audio file could not be created.") }
    defer { ExtAudioFileDispose(file) }
    var input = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 32,
      mReserved: 0
    )
    let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, size, &input) == noErr else {
      throw WisperError.storage("The test audio file could not be set up.")
    }
    var samples = tone(seconds)
    let count = UInt32(samples.count)
    let status = samples.withUnsafeMutableBytes { bytes in
      var list = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: 1,
          mDataByteSize: UInt32(bytes.count),
          mData: bytes.baseAddress
        )
      )
      return ExtAudioFileWrite(file, count, &list)
    }
    guard status == noErr else { throw WisperError.storage("The test audio file could not be written.") }
    try whileOpen()
  }

  /// Writes `seconds` of a tone as the plain copy capture keeps of a file it is still writing:
  /// 16-bit, 16 kHz, mono `.wav`.
  static func writeCopy(_ seconds: Double, to url: URL) throws {
    let sound = tone(seconds).map { Int16(($0 * Float(Int16.max)).rounded()) }
    var data = Data()
    func add(_ text: String) { data.append(contentsOf: text.utf8) }
    func add32(_ value: Int) {
      withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) }
    }
    func add16(_ value: Int) {
      withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) }
    }
    add("RIFF")
    add32(36 + sound.count * 2)
    add("WAVE")
    add("fmt ")
    add32(16)
    add16(1)
    add16(1)
    add32(Int(sampleRate))
    add32(Int(sampleRate) * 2)
    add16(2)
    add16(16)
    add("data")
    add32(sound.count * 2)
    sound.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: url)
  }
}

/// A library that can be told to fail the next saves of a meeting, as a full disk would.
actor MeetingFailingLibrary: Library {
  private let inner = InMemoryLibrary()
  private var failures = 0

  /// Makes the next `count` calls of `updateMeeting` throw.
  func failNextUpdates(_ count: Int) { failures = count }

  func settings() async throws -> Settings { await inner.settings() }
  func updateSettings(_ change: @Sendable (inout Settings) -> Void) async throws -> Settings {
    await inner.updateSettings(change)
  }
  func words() async throws -> [DictionaryWord] { await inner.words() }
  func save(_ word: DictionaryWord) async throws { await inner.save(word) }
  func deleteWord(_ id: DictionaryWord.ID) async throws { await inner.deleteWord(id) }
  func snippets() async throws -> [Snippet] { await inner.snippets() }
  func save(_ snippet: Snippet) async throws { await inner.save(snippet) }
  func deleteSnippet(_ id: Snippet.ID) async throws { await inner.deleteSnippet(id) }
  func dictations(search: String?, limit: Int?) async throws -> [Dictation] {
    await inner.dictations(search: search, limit: limit)
  }
  func save(_ dictation: Dictation) async throws { await inner.save(dictation) }
  func deleteDictations(_ ids: Set<Dictation.ID>) async throws { await inner.deleteDictations(ids) }
  func deleteAllDictations() async throws { await inner.deleteAllDictations() }
  func dictationAudioDirectory() async throws -> URL { try await inner.dictationAudioDirectory() }
  func meetings(search: String?) async throws -> [Meeting] { await inner.meetings(search: search) }
  func meeting(_ id: Meeting.ID) async throws -> Meeting? { await inner.meeting(id) }
  func save(_ meeting: Meeting) async throws { await inner.save(meeting) }
  func updateMeeting(_ id: Meeting.ID, _ change: @Sendable (inout Meeting) -> Void) async throws -> Meeting? {
    if failures > 0 {
      failures -= 1
      throw WisperError.storage("The disk is full.")
    }
    return await inner.updateMeeting(id, change)
  }
  func deleteMeeting(_ id: Meeting.ID) async throws { await inner.deleteMeeting(id) }
  func audioDirectory(forMeeting id: Meeting.ID) async throws -> URL {
    try await inner.audioDirectory(forMeeting: id)
  }
  nonisolated func changes() -> AsyncStream<LibraryChange> { inner.changes() }
}
