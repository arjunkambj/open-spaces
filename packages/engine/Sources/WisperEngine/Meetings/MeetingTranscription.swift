import Foundation
import WisperDomain

/// The transcript of one meeting, built from its audio chunks.
///
/// Chunks come in as capture finishes them, or from the manifest an earlier run left behind.
/// A few are transcribed at a time, in any order. Every step is written to the manifest, so
/// nothing that was transcribed is lost when the app quits.
actor MeetingTranscription {
  struct Options: Sendable {
    var model: String
    var language: String?
    var vocabulary: [String]
    /// How many chunks are transcribed at the same time.
    var concurrency: Int
    /// How often one chunk is tried before it is left for a later retry.
    var attempts: Int
    /// The wait before the second try. Later tries wait longer.
    var retryDelay: Duration
  }

  struct Progress: Sendable, Equatable {
    /// The transcript so far, oldest first, with echoes removed.
    var segments: [TranscriptSegment]
    var chunkCount: Int
    /// Chunks that are not transcribed: waiting, in progress or failed.
    var unfinished: Int
    /// Why the most recent chunk failed. `nil` when nothing is unfinished.
    var error: WisperError?
    /// Where the last chunk ends, in seconds from the start of the meeting.
    var end: TimeInterval
  }

  /// Yields each time `progress()` would return something new.
  nonisolated let changes: AsyncStream<Void>
  private let changed: AsyncStream<Void>.Continuation
  private let directory: URL
  private let transcriber: any Transcriber
  private let options: Options

  private var manifest: MeetingManifest
  private var waiting: [Int] = []
  private var active: Set<Int> = []
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var lastError: WisperError?
  private var abandoned = false

  /// Picks up the manifest in `directory` when there is one.
  init(directory: URL, transcriber: any Transcriber, options: Options) {
    self.directory = directory
    self.transcriber = transcriber
    self.options = options
    manifest = MeetingManifest.read(from: directory) ?? MeetingManifest()
    (changes, changed) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
  }

  deinit { changed.finish() }

  /// Takes a chunk capture has just finished and starts transcribing it.
  func add(_ chunk: AudioChunk) {
    guard !abandoned else { return }
    manifest.chunks.append(
      MeetingManifest.Chunk(
        file: chunk.url.lastPathComponent,
        track: chunk.track,
        offset: chunk.offset,
        duration: chunk.duration
      )
    )
    persist()
    waiting.append(manifest.chunks.count - 1)
    pump()
  }

  /// Tries every chunk again that is not transcribed and not already being worked on.
  func retryUnfinished() {
    for index in manifest.chunks.indices
    where manifest.chunks[index].state != .done && !active.contains(index) && !waiting.contains(index) {
      manifest.chunks[index].state = .pending
      waiting.append(index)
    }
    pump()
  }

  /// Gives the meeting up: nothing more is started or written to disk. Returns once the
  /// chunks already being transcribed have come back, so the folder can be removed safely.
  func abandon() async {
    abandoned = true
    waiting = []
    await waitUntilIdle()
  }

  /// Returns once no chunk is waiting or being transcribed.
  func waitUntilIdle() async {
    guard !isIdle else { return }
    await withCheckedContinuation { idleWaiters.append($0) }
  }

  func progress() -> Progress {
    let unfinished = manifest.chunks.filter { $0.state != .done }.count
    let heard = manifest.chunks.filter { $0.state == .done }.flatMap(\.segments)
    return Progress(
      segments: EchoFilter.removeEcho(from: heard).sorted(by: MeetingTranscription.inOrder),
      chunkCount: manifest.chunks.count,
      unfinished: unfinished,
      error: unfinished > 0 ? lastError : nil,
      end: manifest.chunks.map { $0.offset + $0.duration }.max() ?? 0
    )
  }

  private var isIdle: Bool { active.isEmpty && waiting.isEmpty }

  private func pump() {
    while active.count < max(1, options.concurrency), !waiting.isEmpty {
      let index = waiting.removeFirst()
      active.insert(index)
      let chunk = manifest.chunks[index]
      Task {
        let outcome = await self.transcribe(chunk)
        self.finished(index, outcome)
      }
    }
  }

  private func finished(_ index: Int, _ outcome: Result<Transcript, WisperError>) {
    active.remove(index)
    switch outcome {
    case .success(let transcript):
      manifest.chunks[index].state = .done
      manifest.chunks[index].segments = MeetingTranscription.segments(
        from: transcript,
        chunk: manifest.chunks[index]
      )
    case .failure(let error):
      manifest.chunks[index].state = .failed
      lastError = error
    }
    persist()
    changed.yield()
    pump()
    guard isIdle else { return }
    let waiters = idleWaiters
    idleWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  /// A manifest that cannot be written only weakens recovery after a crash, so the meeting goes on.
  private func persist() {
    guard !abandoned else { return }
    try? manifest.write(to: directory)
  }

  private nonisolated func transcribe(_ chunk: MeetingManifest.Chunk) async -> Result<Transcript, WisperError>
  {
    let audio = directory.appendingPathComponent(chunk.file)
    guard FileManager.default.fileExists(atPath: audio.path) else {
      return .failure(.notFound("Part of the recording"))
    }
    let request = TranscriptionRequest(
      audio: audio,
      model: options.model,
      language: options.language,
      vocabulary: options.vocabulary
    )
    let attempts = max(1, options.attempts)
    var failure = WisperError.noSpeech
    for attempt in 1...attempts {
      do {
        return .success(try await transcriber.transcribe(request))
      } catch WisperError.noSpeech {
        return .success(Transcript(text: ""))
      } catch let error as WisperError {
        failure = error
      } catch {
        failure = .invalidResponse(error.localizedDescription)
      }
      guard MeetingTranscription.isWorthRetrying(failure), attempt < attempts else { break }
      try? await Task.sleep(for: options.retryDelay * attempt)
    }
    return .failure(failure)
  }

  /// Trying again right away cannot fix a missing key, a refused key or a missing file.
  private static func isWorthRetrying(_ error: WisperError) -> Bool {
    switch error {
    case .missingAPIKey, .invalidAPIKey, .notFound, .permissionDenied: false
    default: true
    }
  }

  /// What was heard in one chunk, with times counted from the start of the meeting.
  ///
  /// When the transcriber gives no timed pieces, the whole text becomes one segment that spans
  /// the chunk. That is the honest answer: where in the chunk each sentence was said is not known.
  private static func segments(from transcript: Transcript, chunk: MeetingManifest.Chunk)
    -> [TranscriptSegment]
  {
    let speaker: Speaker = chunk.track == .microphone ? .me : .others
    let length = max(0, chunk.duration)
    func inChunk(_ time: TimeInterval) -> TimeInterval {
      length > 0 ? min(max(0, time), length) : max(0, time)
    }

    let timed = transcript.segments.compactMap { piece -> TranscriptSegment? in
      let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      let start = inChunk(piece.start)
      return TranscriptSegment(
        speaker: speaker,
        start: chunk.offset + start,
        end: chunk.offset + max(start, inChunk(piece.end)),
        text: text
      )
    }
    guard timed.isEmpty else { return timed }
    let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return [] }
    return [TranscriptSegment(speaker: speaker, start: chunk.offset, end: chunk.offset + length, text: text)]
  }

  /// Oldest first. Ties are broken the same way every time so the transcript does not jump around.
  private static func inOrder(_ a: TranscriptSegment, _ b: TranscriptSegment) -> Bool {
    if a.start != b.start { return a.start < b.start }
    if a.speaker != b.speaker { return a.speaker == .me }
    if a.end != b.end { return a.end < b.end }
    return a.id.uuidString < b.id.uuidString
  }
}
