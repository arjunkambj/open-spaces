import Foundation
import Observation
import WisperDomain

/// Runs a dictation from the first key press to inserted text.
///
/// `start` begins recording, `finish` turns the recording into text and puts
/// it into the target, `cancel` throws it away. Everything in between
/// (capture, transcription, dictionary, clean-up, snippets, history) happens
/// inside. Views observe `phase` and `level`.
///
/// What a caller can rely on:
/// - One dictation at a time. `start` while busy and a second `finish` do nothing.
/// - Words are never lost. When text cannot be made, a failed entry with its
///   audio goes into history and `retry` can run it again. When text was made
///   but could not be inserted, it is saved to history as a normal entry.
/// - The inserted text is exactly `Dictation.text`. No space is added after
///   it: the engine cannot see what is around the cursor, and a stray space
///   is wrong in a search field, a message box or after a pasted link.
/// - A recording shorter than 0.3 seconds is a slip of the finger and is dropped.
@MainActor
@Observable
public final class DictationEngine {
  public enum Phase: Equatable, Sendable {
    case idle
    /// Recording. `handsFree` means it keeps going until `finish()` is called
    /// (as opposed to ending when the key is released).
    case recording(mode: DictationMode, since: Date, handsFree: Bool)
    /// Recording is over; text is being made.
    case processing(mode: DictationMode)
    /// The last dictation failed. Cleared by the next `start` or by `dismissFailure`.
    case failed(message: String)
  }

  public private(set) var phase: Phase = .idle
  /// Microphone loudness while recording, 0...1.
  public private(set) var level: Float = 0
  /// The most recent finished dictation of this session.
  public private(set) var last: Dictation?

  /// The longest a recording may run, in seconds (10 minutes unless changed).
  /// When it is reached the engine finishes on its own and inserts the text,
  /// so a key that got stuck or a forgotten hands-free session cannot record
  /// for hours. Read when `start` is called. `.infinity` means no limit.
  @ObservationIgnored public var recordingLimit: TimeInterval = 600

  /// Recordings shorter than this hold no speech.
  static let shortestRecording: TimeInterval = 0.3

  @ObservationIgnored private let library: any Library
  @ObservationIgnored private let capture: any AudioCapture
  @ObservationIgnored private let target: any TextTarget
  @ObservationIgnored private let pipeline: DictationPipeline

  /// The recording in progress, until `finish` or `cancel` takes it.
  @ObservationIgnored private var take: Take?
  /// The newest recording, kept so the next one can wait for its microphone to close.
  @ObservationIgnored private var previous: Take?
  /// The work that follows a recording: stopping, making the text, inserting, saving.
  @ObservationIgnored private var work: Task<Dictation?, Never>?
  /// Goes up whenever a run begins or is cancelled, so work that was already
  /// under way knows it is no longer the current run.
  @ObservationIgnored private var epoch = 0
  /// The newest finished dictation when it could not be stored (history is
  /// off, or saving failed). `pasteLast` uses it.
  @ObservationIgnored private var unsaved: Dictation?

  public init(
    library: any Library,
    capture: any AudioCapture,
    transcriber: any Transcriber,
    languageModel: any LanguageModel,
    target: any TextTarget
  ) {
    self.library = library
    self.capture = capture
    self.target = target
    pipeline = DictationPipeline(
      library: library,
      transcriber: transcriber,
      languageModel: languageModel,
      target: target
    )
  }

  /// Changes what the recording in progress is, without interrupting it:
  /// the microphone stays open and nothing said so far is lost. Used when a
  /// held key grows into another shortcut (push to talk into hands-free or
  /// command mode). Does nothing unless `phase` is `.recording`.
  public func change(mode: DictationMode, handsFree: Bool) {
    guard case .recording(_, let since, _) = phase else { return }
    phase = .recording(mode: mode, since: since, handsFree: handsFree)
  }

  /// Starts recording. Does nothing unless `phase` is `.idle` or `.failed`.
  ///
  /// `phase` is `.recording` when this returns. The microphone opens just
  /// after; if it cannot, `phase` becomes `.failed`.
  public func start(mode: DictationMode = .dictation, handsFree: Bool = false) {
    switch phase {
    case .idle, .failed: break
    case .recording, .processing: return
    }
    let library = library
    let capture = capture
    let earlier = previous
    let starting = Task { () -> Take.Started in
      // Let the last recording let go of the microphone first.
      await earlier?.ended()
      do {
        let settings = try await library.settings()
        let request = CaptureRequest(
          tracks: [.microphone],
          microphoneID: settings.microphoneID,
          directory: try await library.dictationAudioDirectory(),
          chunkSeconds: nil
        )
        return .success(try await capture.start(request))
      } catch {
        return .failure(error)
      }
    }
    let take = Take(starting: starting)
    self.take = take
    previous = take
    epoch += 1
    level = 0
    phase = .recording(mode: mode, since: Date(), handsFree: handsFree)

    take.watch = Task { [weak self, weak take] in
      switch await starting.value {
      case .failure(let error):
        guard let self, let take, self.take === take else { return }
        self.take = nil
        take.release()
        self.phase = .failed(message: DictationText.message(for: error))
      case .success(let session):
        for await value in session.levels {
          guard let self, let take, self.take === take else { break }
          self.level = value.isFinite ? min(max(value, 0), 1) : 0
        }
        // The engine went away in the middle of a recording: close the microphone.
        if self == nil { await session.cancel() }
      }
    }
    // A limit of a day or more (or one that is not a number) is no limit at all.
    let limit = recordingLimit
    guard limit < 86_400 else { return }
    take.limit = Task { [weak self, weak take] in
      try? await Task.sleep(for: .seconds(max(limit, 0)))
      guard !Task.isCancelled, let self, let take, self.take === take else { return }
      await self.finish()
    }
  }

  /// Stops recording, makes the text and inserts it into the target.
  /// Returns the saved dictation, or `nil` when nothing was recorded, no
  /// speech was heard, or it failed (then `phase` is `.failed`).
  ///
  /// When the text was made but could not be inserted, it is still saved to
  /// history and set as `last`; the result is `nil` and the failure message
  /// says where the text is.
  @discardableResult
  public func finish() async -> Dictation? {
    guard case .recording(let mode, let since, _) = phase, let take else { return nil }
    self.take = nil
    level = 0
    let stopping = take.stop()
    let epoch = epoch
    // A task of the engine's own, so `cancel` can stop it and the caller's task cannot cut it short.
    let job = Task { await self.complete(stopping, mode: mode, since: since, epoch: epoch) }
    work = job
    return await job.value
  }

  /// Stops recording and discards the audio. While text is being made, stops
  /// that too: nothing is inserted and nothing is saved.
  /// Does nothing when `phase` is `.idle` or `.failed`.
  public func cancel() {
    switch phase {
    case .idle, .failed: return
    case .recording, .processing: break
    }
    epoch += 1
    if let take {
      self.take = nil
      take.discard()
    }
    work?.cancel()
    work = nil
    level = 0
    phase = .idle
  }

  /// Runs a failed dictation's kept audio through the pipeline again.
  ///
  /// On success the text is inserted and the history entry (same `id`)
  /// becomes a normal one. Does nothing while recording or processing.
  ///
  /// Pass `insert: false` to only save the text to history and return it:
  /// for a retry started from the app's own window, where there is no text
  /// field of another app waiting for it.
  @discardableResult
  public func retry(_ id: Dictation.ID, insert: Bool = true) async -> Dictation? {
    switch phase {
    case .idle, .failed: break
    case .recording, .processing: return nil
    }
    // The real mode is set as soon as the entry has been read.
    phase = .processing(mode: .dictation)
    epoch += 1
    let epoch = epoch
    let job = Task { await self.reprocess(id, insert: insert, epoch: epoch) }
    work = job
    return await job.value
  }

  /// Inserts the most recent dictation from history into the target again.
  ///
  /// Does nothing while recording or processing. When there is nothing to
  /// paste, or the text cannot be inserted, `phase` becomes `.failed`.
  public func pasteLast() async {
    switch phase {
    case .idle, .failed: break
    case .recording, .processing: return
    }
    let epoch = epoch
    var problem: String?
    do {
      var text = unsaved?.text
      if text == nil {
        text = try await library.dictations().first { !$0.failed && !$0.text.isEmpty }?.text
      }
      if let text {
        try await target.insert(text)
      } else {
        problem = "There is no dictation to paste yet."
      }
    } catch {
      problem = DictationText.message(for: error)
    }
    // Leave the phase alone if a new dictation began in the meantime.
    guard epoch == self.epoch else { return }
    phase = problem.map { .failed(message: $0) } ?? .idle
  }

  public func dismissFailure() {
    if case .failed = phase { phase = .idle }
  }

  public var isRecording: Bool {
    if case .recording = phase { return true }
    return false
  }

  public var isBusy: Bool { phase != .idle }

  // MARK: - From a recording to text

  /// One piece of audio on its way to becoming a history entry.
  private struct Entry {
    var id: Dictation.ID
    var createdAt: Date
    var mode: DictationMode
    var duration: TimeInterval
    var audio: URL
    /// The failed history entry being tried again, or `nil` for a new recording.
    var original: Dictation?

    func dictation(from draft: DictationPipeline.Draft) -> Dictation {
      Dictation(
        id: id,
        createdAt: createdAt,
        mode: mode,
        rawText: draft.raw,
        text: draft.text,
        duration: duration,
        appName: original?.appName ?? draft.context.appName,
        bundleID: original?.bundleID ?? draft.context.bundleID
      )
    }
  }

  private func complete(
    _ stopping: Task<Take.Stopped, Never>,
    mode: DictationMode,
    since: Date,
    epoch: Int
  ) async -> Dictation? {
    let files: [AudioChunk]
    switch await stopping.value {
    case .success(let chunks): files = chunks
    case .failure(let error):
      settle(.failed(message: DictationText.message(for: error)), epoch: epoch)
      return nil
    }
    let recording = files.first { $0.track == .microphone } ?? files.first
    await DictationAudio.delete(files.map(\.url).filter { $0 != recording?.url })
    guard epoch == self.epoch else {
      await DictationAudio.delete(files.map(\.url))
      return nil
    }
    guard let recording else {
      // The microphone gave nothing. After a quick tap that is expected; after real talking it is a fault.
      let tapped = Date().timeIntervalSince(since) < Self.shortestRecording
      let message = DictationText.message(for: WisperError.captureFailed("no audio was recorded."))
      settle(tapped ? .idle : .failed(message: message), epoch: epoch)
      return nil
    }
    guard recording.duration >= Self.shortestRecording else {
      await DictationAudio.delete([recording.url])
      settle(.idle, epoch: epoch)
      return nil
    }
    phase = .processing(mode: mode)
    let id = UUID()
    let audio = await DictationAudio.adopt(recording.url, for: id)
    let entry = Entry(id: id, createdAt: since, mode: mode, duration: recording.duration, audio: audio)
    return await process(entry, epoch: epoch)
  }

  private func reprocess(_ id: Dictation.ID, insert: Bool, epoch: Int) async -> Dictation? {
    do {
      guard let original = try await library.dictations().first(where: { $0.id == id }) else {
        throw WisperError.notFound("That dictation")
      }
      guard original.failed else {
        settle(.idle, epoch: epoch)
        return nil
      }
      // Only a file name is trusted: the entry may have been edited by hand.
      let name = original.audioFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
      let audio = try await library.dictationAudioDirectory().appendingPathComponent(name)
      guard !name.isEmpty, await DictationAudio.exists(audio) else {
        throw WisperError.notFound("The recording of that dictation")
      }
      guard epoch == self.epoch else { return nil }
      phase = .processing(mode: original.mode)
      let entry = Entry(
        id: original.id,
        createdAt: original.createdAt,
        mode: original.mode,
        duration: original.duration,
        audio: audio,
        original: original
      )
      return await process(entry, insert: insert, epoch: epoch)
    } catch {
      settle(.failed(message: DictationText.message(for: error)), epoch: epoch)
      return nil
    }
  }

  private func process(_ entry: Entry, insert: Bool = true, epoch: Int) async -> Dictation? {
    let outcome = await pipeline.run(audio: entry.audio, mode: entry.mode)
    guard epoch == self.epoch else {
      // Cancelled while the text was being made. A retry keeps its audio: the failed entry still needs it.
      if entry.original == nil { await DictationAudio.delete([entry.audio]) }
      return nil
    }
    switch outcome {
    case .silence: return await heardNothing(entry, epoch: epoch)
    case .failed(let draft, let error): return await keepForRetry(entry, draft, error, epoch: epoch)
    case .written(let draft): return await deliver(entry, draft, insert: insert, epoch: epoch)
    }
  }

  /// Inserts the text and saves the dictation.
  private func deliver(
    _ entry: Entry,
    _ draft: DictationPipeline.Draft,
    insert: Bool = true,
    epoch: Int
  ) async -> Dictation? {
    var dictation = entry.dictation(from: draft)
    var insertProblem: String?
    if insert {
      do {
        try await target.insert(draft.text)
      } catch {
        insertProblem = DictationText.message(for: error)
      }
    }
    if insertProblem != nil, epoch != self.epoch {
      // Cancelled before the text went in: throw the dictation away, as asked.
      if entry.original == nil { await DictationAudio.delete([entry.audio]) }
      return nil
    }

    dictation.audioFile = draft.keepsAudio ? entry.audio.lastPathComponent : nil
    var saveProblem: String?
    do {
      // Saved even when history is off, so the library can apply that setting.
      try await library.save(dictation)
    } catch {
      saveProblem = DictationText.message(for: error)
    }
    // The audio stays only while a history entry points at it: this one, or the failed one a retry came from.
    let audioInUse = saveProblem == nil ? dictation.audioFile != nil : entry.original != nil
    if !audioInUse {
      await DictationAudio.delete([entry.audio])
      dictation.audioFile = nil
    }

    let stored = saveProblem == nil && draft.keepsHistory
    unsaved = stored ? nil : dictation
    last = dictation
    if let insertProblem {
      let place =
        stored
        ? "Your text is saved in your history."
        : "Your text is not lost: use Paste last transcript to try again."
      settle(.failed(message: "\(insertProblem) \(place)"), epoch: epoch)
      return nil
    }
    if let saveProblem {
      settle(.failed(message: saveProblem), epoch: epoch)
      return nil
    }
    settle(.idle, epoch: epoch)
    return dictation
  }

  /// No text could be made: keeps the audio and a failed entry, so nothing that was said is lost.
  private func keepForRetry(
    _ entry: Entry,
    _ draft: DictationPipeline.Draft,
    _ error: any Error,
    epoch: Int
  ) async -> Dictation? {
    let message = DictationText.message(for: error)
    if draft.keepsHistory {
      var failed = entry.dictation(from: draft)
      failed.text = ""
      failed.audioFile = entry.audio.lastPathComponent
      failed.failure = message
      // If even this cannot be saved, the audio file is left in the folder rather than deleted.
      try? await library.save(failed)
    } else if entry.original == nil {
      // History is off: nothing about a dictation may stay on disk.
      await DictationAudio.delete([entry.audio])
    }
    settle(.failed(message: message), epoch: epoch)
    return nil
  }

  private func heardNothing(_ entry: Entry, epoch: Int) async -> Dictation? {
    guard var original = entry.original else {
      await DictationAudio.delete([entry.audio])
      settle(.idle, epoch: epoch)
      return nil
    }
    // A retry that hears nothing says so on the entry, and leaves it for the person to delete.
    let message = DictationText.message(for: WisperError.noSpeech)
    original.failure = message
    try? await library.save(original)
    settle(.failed(message: message), epoch: epoch)
    return nil
  }

  /// Ends a run in `phase`, unless `cancel` already ended it.
  private func settle(_ phase: Phase, epoch: Int) {
    guard epoch == self.epoch else { return }
    work = nil
    level = 0
    self.phase = phase
  }
}

/// One recording, from the key press until its microphone is closed.
@MainActor
private final class Take {
  typealias Started = Result<any CaptureSession, any Error>
  typealias Stopped = Result<[AudioChunk], any Error>

  /// Opens the microphone. Still running when a key was only tapped.
  let starting: Task<Started, Never>
  /// Shows loudness, and reports a microphone that could not be opened.
  var watch: Task<Void, Never>?
  /// Ends a recording that runs too long.
  var limit: Task<Void, Never>?
  private var ending: Task<Stopped, Never>?

  init(starting: Task<Started, Never>) {
    self.starting = starting
  }

  /// Stops the tasks that follow the recording.
  func release() {
    watch?.cancel()
    limit?.cancel()
    watch = nil
    limit = nil
  }

  /// Closes the microphone once it has opened and returns the audio files.
  /// Runs in a task of its own, so it always runs to the end.
  func stop() -> Task<Stopped, Never> {
    release()
    let starting = starting
    let task = Task { () -> Stopped in
      switch await starting.value {
      case .failure(let error):
        return .failure(error)
      case .success(let session):
        // Listen before stopping, so no file is missed.
        let collecting = Task { () -> [AudioChunk] in
          var files: [AudioChunk] = []
          for await chunk in session.chunks { files.append(chunk) }
          return files
        }
        await session.stop()
        return .success(await collecting.value)
      }
    }
    ending = task
    return task
  }

  /// Closes the microphone once it has opened and throws the audio away.
  func discard() {
    release()
    let starting = starting
    ending = Task { () -> Stopped in
      if case .success(let session) = await starting.value { await session.cancel() }
      return .success([])
    }
  }

  /// Returns when the microphone has been closed (or right away if nobody has asked for that yet).
  func ended() async {
    _ = await ending?.value
  }
}
