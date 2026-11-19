import Foundation
import WisperDomain

/// The transcript of one meeting, built from its audio chunks.
///
/// Chunks come in as capture finishes them, or from the audio folder an earlier run left behind.
/// A few are transcribed at a time, in any order. Every step is written to the manifest, so
/// nothing that was transcribed is lost when the app quits.
///
/// An answer that trying again cannot change (the model name is not accepted, the key is
/// refused) stops the queue: the chunks still waiting are left for the next `retryUnfinished`,
/// instead of each being sent off to get the same answer.
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
    /// Whether part of the recording was lost for good: see `MeetingManifest.lostAudio`.
    var lostAudio = false
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
  /// Chunks in a row that the server would not take, with none accepted in between. One can
  /// be about a single file; two say it is the request itself the server will not take.
  private var refusals = 0
  /// Set once the queue is stopped. Nothing more is started until `retryUnfinished`.
  private var stopped = false

  /// The transcript of a recording that is about to start: nothing is read from `directory`.
  init(directory: URL, transcriber: any Transcriber, options: Options) {
    self.init(directory: directory, transcriber: transcriber, options: options, manifest: MeetingManifest())
  }

  private init(directory: URL, transcriber: any Transcriber, options: Options, manifest: MeetingManifest) {
    self.directory = directory
    self.transcriber = transcriber
    self.options = options
    self.manifest = manifest
    (changes, changed) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
  }

  /// Picks up the audio an earlier run left in `directory`: what its manifest says, and every
  /// audio file the manifest does not list. The files are read away from the caller's actor.
  /// Not for a folder that is being recorded into.
  static func resuming(
    in directory: URL,
    transcriber: any Transcriber,
    options: Options
  ) async -> MeetingTranscription {
    let manifest = await Task.detached { MeetingManifest.load(from: directory) }.value
    return MeetingTranscription(
      directory: directory,
      transcriber: transcriber,
      options: options,
      manifest: manifest
    )
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
    // After a final refusal the chunk waits, like the others, for the next round.
    guard !stopped else { return }
    waiting.append(manifest.chunks.count - 1)
    pump()
  }

  /// Starts a new round: tries every chunk again that is not transcribed and not already being
  /// worked on. Chunks that were never tried go first, so one file the server will not take
  /// does not hold up the others.
  func retryUnfinished() {
    stopped = false
    refusals = 0
    let open = manifest.chunks.indices.filter { index in
      manifest.chunks[index].state != .done && !active.contains(index) && !waiting.contains(index)
    }
    waiting += open.filter { manifest.chunks[$0].state == .pending }
    waiting += open.filter { manifest.chunks[$0].state == .failed }
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
      end: manifest.chunks.map { $0.offset + $0.duration }.max() ?? 0,
      lostAudio: manifest.lostAudio == true
    )
  }

  private var isIdle: Bool { active.isEmpty && waiting.isEmpty }

  private func pump() {
    while !stopped, active.count < max(1, options.concurrency), !waiting.isEmpty {
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
      refusals = 0
    case .failure(let error):
      manifest.chunks[index].state = .failed
      // Once stopped, the reason for stopping is the one to show: it names what to fix.
      if !stopped { lastError = error }
      if MeetingTranscription.isRefusedByTheServer(error) { refusals += 1 }
      if MeetingTranscription.isAboutTheKey(error) || refusals >= 2 {
        // The same answer would come back for every chunk. The rest stay as they are.
        stopped = true
        waiting = []
      }
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

  /// Trying again right away cannot fix a missing file, or an answer that is final.
  private static func isWorthRetrying(_ error: WisperError) -> Bool {
    switch error {
    case .notFound, .permissionDenied: false
    default: !isFinal(error)
    }
  }

  /// Whether the same request would get the same answer however often it is sent: there is
  /// no key, or the server said no to it.
  private static func isFinal(_ error: WisperError) -> Bool {
    isAboutTheKey(error) || isRefusedByTheServer(error)
  }

  /// There is no key, or it is not accepted: no chunk will get through until that is fixed.
  private static func isAboutTheKey(_ error: WisperError) -> Bool {
    switch error {
    case .missingAPIKey, .invalidAPIKey: true
    default: false
    }
  }

  /// The server understood the request and will not do it: a model name it does not know, a
  /// setting it does not take, a file it cannot read. "Too slow" (408) and "too many requests"
  /// (429) are the two answers in that range that do pass.
  private static func isRefusedByTheServer(_ error: WisperError) -> Bool {
    guard case .server(let status, _) = error else { return false }
    return (400...499).contains(status) && status != 408 && status != 429
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
