import Foundation
import SpacesDomain

/// The transcript of one meeting, built from its audio chunks.
///
/// Chunks come in as capture finishes them, or from the audio folder an earlier run left behind.
/// A few are transcribed at a time, in any order. Every step is written to the manifest, so
/// nothing that was transcribed is lost when the app quits.
///
/// An answer that trying again cannot change (the model name is not accepted, the key is
/// refused) stops the queue: the chunks still waiting are left for the next `retryUnfinished`,
/// instead of each being sent off to get the same answer.
///
/// **Voices.** With `Options.separatesVoices`, the voices on the system track are told apart
/// and named "Speaker 1", "Speaker 2"… The transcriber labels each request on its own, so a
/// voice gets its name from a sample: the first time a voice speaks long enough in one go, that
/// stretch is kept as its sample (in the manifest), and every later system chunk is sent with
/// the samples so far. Those chunks therefore go one at a time. A voice that never speaks long
/// enough, or one past `Voices.mostKnown`, can get a new number in each chunk: the notes and
/// the person can still give two numbers the same name.
actor MeetingTranscription {
  struct Options: Sendable {
    var model: String
    var language: String?
    var vocabulary: [String]
    /// Whether to tell the voices on the system track apart. Only OpenAI's own server can.
    var separatesVoices = false
  }

  /// How many chunks are transcribed at the same time.
  private static let concurrency = 4
  /// How often one chunk is tried before it is left for a later retry.
  private static let attempts = 3
  /// The wait before a chunk's second try. Later tries wait longer.
  private static let retryDelay: Duration = .seconds(2)

  struct Progress: Sendable, Equatable {
    /// The transcript so far, oldest first, with echoes removed.
    var segments: [TranscriptSegment]
    var chunkCount: Int
    /// Chunks that are not transcribed: waiting, in progress or failed.
    var unfinished: Int
    /// Why the most recent chunk failed. `nil` when nothing is unfinished.
    var error: SpacesError?
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
  private var lastError: SpacesError?
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
    while !stopped, active.count < MeetingTranscription.concurrency, let next = nextToStart() {
      let index = waiting.remove(at: next)
      active.insert(index)
      let chunk = manifest.chunks[index]
      let voices = tellsVoicesApart(chunk) ? knownVoices() : nil
      Task {
        let outcome = await self.transcribe(chunk, voices: voices)
        self.finished(index, outcome)
      }
    }
  }

  /// Where in `waiting` the next chunk to start is. A system chunk whose voices are told apart
  /// waits while another one is out: it is to be sent with the voices that one finds.
  private func nextToStart() -> Int? {
    guard options.separatesVoices, active.contains(where: { manifest.chunks[$0].track == .system }) else {
      return waiting.indices.first
    }
    return waiting.firstIndex { manifest.chunks[$0].track != .system }
  }

  private func tellsVoicesApart(_ chunk: MeetingManifest.Chunk) -> Bool {
    options.separatesVoices && chunk.track == .system
  }

  private func knownVoices() -> Voices {
    Voices(
      known: (manifest.voices ?? []).map { voice in
        Voices.Sample(
          name: voice.name,
          audio: directory.appendingPathComponent(voice.file),
          start: voice.start,
          end: voice.end
        )
      }
    )
  }

  private func finished(_ index: Int, _ outcome: Result<Transcript, SpacesError>) {
    active.remove(index)
    switch outcome {
    case .success(let transcript):
      let chunk = manifest.chunks[index]
      var names: [String: Speaker] = [:]
      if tellsVoicesApart(chunk) {
        var voices = manifest.voices ?? []
        names = MeetingTranscription.names(in: transcript, chunk: chunk, voices: &voices, after: lastNumber())
        if voices != (manifest.voices ?? []) { manifest.voices = voices }
      }
      manifest.chunks[index].state = .done
      manifest.chunks[index].segments = MeetingTranscription.segments(
        from: transcript,
        chunk: chunk,
        names: names
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

  /// The highest number a voice told apart has had in this meeting so far, 0 before the first.
  private func lastNumber() -> Int {
    let speakers =
      manifest.chunks.flatMap(\.segments).map(\.speaker)
      + (manifest.voices ?? []).map { Speaker.named($0.name) }
    return speakers.compactMap(\.unnamedNumber).max() ?? 0
  }

  private nonisolated func transcribe(
    _ chunk: MeetingManifest.Chunk,
    voices: Voices?
  ) async -> Result<Transcript, SpacesError> {
    let audio = directory.appendingPathComponent(chunk.file)
    guard FileManager.default.fileExists(atPath: audio.path) else {
      return .failure(.notFound("Part of the recording"))
    }
    let request = TranscriptionRequest(
      audio: audio,
      model: options.model,
      language: options.language,
      vocabulary: options.vocabulary,
      voices: voices
    )
    let attempts = MeetingTranscription.attempts
    var failure = SpacesError.noSpeech
    for attempt in 1...attempts {
      do {
        return .success(try await transcriber.transcribe(request))
      } catch SpacesError.noSpeech {
        return .success(Transcript(text: ""))
      } catch let error as SpacesError {
        failure = error
      } catch {
        failure = .invalidResponse(error.localizedDescription)
      }
      guard MeetingTranscription.isWorthRetrying(failure), attempt < attempts else { break }
      try? await Task.sleep(for: MeetingTranscription.retryDelay * attempt)
    }
    return .failure(failure)
  }

  /// Trying again right away cannot fix a missing file, or an answer that is final.
  private static func isWorthRetrying(_ error: SpacesError) -> Bool {
    switch error {
    case .notFound, .permissionDenied: false
    default: !isFinal(error)
    }
  }

  /// Whether the same request would get the same answer however often it is sent: there is
  /// no key, or the server said no to it.
  private static func isFinal(_ error: SpacesError) -> Bool {
    isAboutTheKey(error) || isRefusedByTheServer(error)
  }

  /// There is no key, it is not accepted, or the server address cannot be used: no chunk will
  /// get through until that is fixed.
  private static func isAboutTheKey(_ error: SpacesError) -> Bool {
    switch error {
    // An unusable server address is the same kind of problem: nothing gets through until Settings is fixed.
    case .missingAPIKey, .invalidAPIKey, .invalidServerAddress: true
    default: false
    }
  }

  /// The server understood the request and will not do it: a model name it does not know, a
  /// setting it does not take, a file it cannot read. "Too slow" (408) and "too many requests"
  /// (429) are the two answers in that range that do pass.
  private static func isRefusedByTheServer(_ error: SpacesError) -> Bool {
    guard case .server(let status, _) = error else { return false }
    return (400...499).contains(status) && status != 408 && status != 429
  }

  /// The meeting's speaker for each label in one system chunk's reply. A known voice keeps its
  /// name. Any other label is a voice new to the meeting and becomes the next "Speaker N",
  /// counting on from `last`. While there is room, a new voice that speaks long enough in one
  /// go has that stretch added to `voices` as its sample.
  private static func names(
    in transcript: Transcript,
    chunk: MeetingManifest.Chunk,
    voices: inout [MeetingManifest.Voice],
    after last: Int
  ) -> [String: Speaker] {
    let known = Set(voices.map(\.name))
    var names: [String: Speaker] = [:]
    var number = last
    for piece in transcript.segments {
      guard let label = piece.speaker, names[label] == nil,
        !piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { continue }
      if known.contains(label) {
        names[label] = .named(label)
        continue
      }
      number += 1
      let speaker = Speaker.unnamed(number)
      names[label] = speaker
      if voices.count < Voices.mostKnown, let sample = sample(of: label, in: transcript, chunk: chunk) {
        voices.append(
          MeetingManifest.Voice(
            name: speaker.label,
            file: chunk.file,
            start: sample.lowerBound,
            end: sample.upperBound
          )
        )
      }
    }
    return names
  }

  /// The longest stretch of the chunk in which only `label` speaks, cut to what a sample may
  /// be. A little is left off both ends, where the voice before or after may still be heard.
  /// `nil` when no piece is long enough.
  private static func sample(
    of label: String,
    in transcript: Transcript,
    chunk: MeetingManifest.Chunk
  ) -> ClosedRange<TimeInterval>? {
    let margin = 0.25
    let length = max(0, chunk.duration)
    let stretches = transcript.segments.filter { $0.speaker == label }.compactMap {
      piece -> ClosedRange<TimeInterval>? in
      let start = min(max(0, piece.start), length) + margin
      let end = min(max(0, piece.end), length) - margin
      guard end - start >= Voices.sampleLength.lowerBound else { return nil }
      return start...min(end, start + Voices.sampleLength.upperBound)
    }
    return stretches.max { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }
  }

  /// What was heard in one chunk, with times counted from the start of the meeting. A piece
  /// the microphone heard is "Me". A piece from the system track is the speaker `names` gives
  /// its label, or "Others" when its voice was not told apart.
  ///
  /// When the transcriber gives no timed pieces, the whole text becomes one segment that spans
  /// the chunk. That is the honest answer: where in the chunk each sentence was said is not known.
  private static func segments(
    from transcript: Transcript,
    chunk: MeetingManifest.Chunk,
    names: [String: Speaker]
  ) -> [TranscriptSegment] {
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
        speaker: speaker == .me ? .me : piece.speaker.flatMap { names[$0] } ?? .others,
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
