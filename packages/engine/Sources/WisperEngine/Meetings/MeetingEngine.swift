import Foundation
import Observation
import WisperDomain

/// Records a meeting and turns it into a transcript and notes.
///
/// `start` begins recording into a new `Meeting`; audio is cut into chunks
/// that are transcribed while the meeting is still going. `stop` finishes the
/// transcript and writes the notes. Views observe `live` and `level`.
@MainActor
@Observable
public final class MeetingEngine {
  /// The meeting being recorded right now.
  public struct Live: Equatable, Sendable {
    public var meetingID: Meeting.ID
    public var title: String
    public var startedAt: Date
    /// Transcript so far, oldest first.
    public var segments: [TranscriptSegment]

    public init(meetingID: Meeting.ID, title: String, startedAt: Date, segments: [TranscriptSegment] = []) {
      self.meetingID = meetingID
      self.title = title
      self.startedAt = startedAt
      self.segments = segments
    }
  }

  public private(set) var live: Live?
  /// Loudness while recording, 0...1.
  public private(set) var level: Float = 0
  /// Meetings whose transcript or notes are being made after `stop`.
  public private(set) var processing: Set<Meeting.ID> = []
  /// Something the user should know about the most recent `toggle` or `start`: why `toggle`
  /// could not start a recording, or that only the microphone is being recorded because system
  /// audio is not allowed. Plain English, ready to show. Cleared by the next start; set it to
  /// `nil` to dismiss it.
  public var lastError: String?

  /// The numbers the engine works with. Tests make them small.
  struct Tuning: Sendable {
    /// Length of one audio chunk. Long enough to give the transcriber context, short enough
    /// that the live transcript moves and a crash loses little.
    var chunkSeconds: TimeInterval = 30
    /// How many chunks are transcribed at the same time.
    var concurrency = 4
    /// How often one chunk is tried before it is left for a later retry.
    var attempts = 3
    /// The wait before a chunk's second try. Later tries wait longer.
    var retryDelay: Duration = .seconds(2)
    /// The shortest time between two saves of the transcript while recording.
    var liveSaveInterval: Duration = .seconds(5)
    /// The most transcript text, in characters, sent to the language model in one request.
    /// About 15,000 tokens: an hour of talk fits in one or two requests, and a small local
    /// model can still take it.
    var notesCharacterLimit = 60_000
  }

  /// A recording in progress and the tasks that feed on it.
  private struct Recording {
    var meetingID: Meeting.ID
    var directory: URL
    var session: any CaptureSession
    var transcription: MeetingTranscription
    var chunks: Task<Void, Never>
    var levels: Task<Void, Never>
    var progress: Task<Void, Never>
    var saver: Task<Void, Never>
  }

  @ObservationIgnored private let library: any Library
  @ObservationIgnored private let capture: any AudioCapture
  @ObservationIgnored private let transcriber: any Transcriber
  @ObservationIgnored private let notes: MeetingNotesWriter
  @ObservationIgnored private let tuning: Tuning
  @ObservationIgnored private var recording: Recording?
  @ObservationIgnored private var isStarting = false
  /// The meeting `start` is setting up, before `live` is set.
  @ObservationIgnored private var startingID: Meeting.ID?

  public convenience init(
    library: any Library,
    capture: any AudioCapture,
    transcriber: any Transcriber,
    languageModel: any LanguageModel
  ) {
    self.init(
      library: library,
      capture: capture,
      transcriber: transcriber,
      languageModel: languageModel,
      tuning: Tuning()
    )
  }

  init(
    library: any Library,
    capture: any AudioCapture,
    transcriber: any Transcriber,
    languageModel: any LanguageModel,
    tuning: Tuning
  ) {
    self.library = library
    self.capture = capture
    self.transcriber = transcriber
    self.tuning = tuning
    notes = MeetingNotesWriter(languageModel: languageModel, characterLimit: tuning.notesCharacterLimit)
  }

  public var isRecording: Bool { live != nil }

  // MARK: - Recording

  /// Starts recording a new meeting and returns its ID. `title` defaults to a
  /// dated placeholder that is replaced by a generated title when notes are written.
  /// Throws `WisperError` when capture cannot start or a meeting is already being recorded.
  @discardableResult
  public func start(title: String? = nil) async throws -> Meeting.ID {
    guard live == nil, recording == nil, !isStarting else {
      throw WisperError.captureFailed("A meeting is already being recorded.")
    }
    isStarting = true
    defer {
      isStarting = false
      startingID = nil
    }
    lastError = nil

    let settings = try await library.settings()
    let startedAt = Date()
    let given = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let meeting = Meeting(
      title: given.isEmpty ? MeetingEngine.placeholderTitle(for: startedAt) : given,
      startedAt: startedAt,
      status: .recording
    )
    let id = meeting.id
    startingID = id
    try await library.save(meeting)

    let directory: URL
    let session: any CaptureSession
    do {
      directory = try await library.audioDirectory(forMeeting: id)
      session = try await startCapture(settings: settings, directory: directory)
    } catch {
      try? await library.deleteMeeting(id)
      throw error
    }

    let transcription = await makeTranscription(in: directory, settings: settings)
    live = Live(meetingID: id, title: meeting.title, startedAt: startedAt)

    let chunks = Task {
      for await chunk in session.chunks { await transcription.add(chunk) }
    }
    let levels = Task { [weak self] in
      for await level in session.levels { self?.level = level }
      self?.level = 0
    }
    // The transcript on screen follows every change. Saving it is paced by `saver`, which
    // holds on to the newest request while it waits.
    let (saveRequests, requestSave) = AsyncStream.makeStream(
      of: Void.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    let progress = Task { [weak self] in
      for await _ in transcription.changes {
        let segments = await transcription.progress().segments
        guard let self, !Task.isCancelled, self.live?.meetingID == id else { break }
        if self.live?.segments != segments {
          self.live?.segments = segments
          requestSave.yield()
        }
      }
      requestSave.finish()
    }
    let saver = Task { [weak self, pause = tuning.liveSaveInterval] in
      for await _ in saveRequests {
        await self?.saveLive(id)
        try? await Task.sleep(for: pause)
      }
    }
    recording = Recording(
      meetingID: id,
      directory: directory,
      session: session,
      transcription: transcription,
      chunks: chunks,
      levels: levels,
      progress: progress,
      saver: saver
    )
    return id
  }

  /// Stops recording. Returns once the meeting is saved as `.processing`;
  /// the transcript and notes are finished in the background and the meeting
  /// then becomes `.ready` (or `.failed`).
  public func stop() async {
    guard let recording else { return }
    self.recording = nil
    let id = recording.meetingID

    await recording.session.stop()
    // Once the chunk stream has ended, every chunk is in the manifest.
    await recording.chunks.value
    recording.progress.cancel()
    recording.saver.cancel()
    recording.levels.cancel()
    await recording.progress.value
    await recording.saver.value
    level = 0

    let snapshot = await recording.transcription.progress()
    let endedAt = Date()
    processing.insert(id)
    var stillThere = true
    do {
      let saved = try await update(id) { meeting in
        meeting.endedAt = endedAt
        meeting.status = .processing
        meeting.segments = snapshot.segments
      }
      stillThere = saved != nil
    } catch {
      // Finishing saves again; a save that failed here is not the end of the meeting.
    }
    live = nil

    guard stillThere else {
      // The meeting was deleted while it was being recorded. Nothing of it is kept.
      Task {
        await recording.transcription.abandon()
        await MeetingEngine.remove(recording.directory)
        self.processing.remove(id)
      }
      return
    }
    Task { await self.finish(id, recording.transcription, directory: recording.directory) }
  }

  /// Starts a meeting when none is being recorded, stops it otherwise.
  /// When starting fails, the reason is put in `lastError`.
  public func toggle() async {
    if recording != nil {
      await stop()
    } else if live == nil, !isStarting {
      do {
        try await start()
      } catch {
        lastError = error.localizedDescription
      }
    }
  }

  // MARK: - After the recording

  /// Writes the AI notes for a meeting again from its transcript.
  /// Throws `WisperError`: `.noSpeech` when the meeting has no transcript.
  public func regenerateNotes(_ id: Meeting.ID) async throws {
    guard let meeting = try await library.meeting(id) else { throw WisperError.notFound("The meeting") }
    // Notes are already on their way.
    guard !processing.contains(id) else { return }
    guard !meeting.segments.isEmpty else { throw WisperError.noSpeech }
    processing.insert(id)
    defer { processing.remove(id) }

    let settings = try await library.settings()
    let draft = try await notes.write(for: meeting, settings: settings)
    let saved = try await update(id) { meeting in
      MeetingEngine.apply(draft, to: &meeting)
      if meeting.failure?.hasPrefix(MeetingEngine.notesFailed) == true { meeting.failure = nil }
    }
    if saved == nil { throw WisperError.notFound("The meeting") }
  }

  /// Processes a `.failed` meeting again from its kept audio. Also finishes a meeting that
  /// is missing part of its transcript or its notes. Returns when the work is done and
  /// throws `WisperError` when the meeting still could not be finished.
  public func retry(_ id: Meeting.ID) async throws {
    guard let meeting = try await library.meeting(id) else { throw WisperError.notFound("The meeting") }
    guard !isBusy(id) else { return }
    processing.insert(id)
    let directory: URL
    let transcription: MeetingTranscription
    do {
      let settings = try await library.settings()
      directory = try await library.audioDirectory(forMeeting: id)
      transcription = await makeTranscription(in: directory, settings: settings)
      let state = await transcription.progress()
      if meeting.status == .ready, meeting.failure == nil, state.unfinished == 0 {
        processing.remove(id)
        return
      }
      if state.chunkCount == 0, meeting.status == .failed, meeting.segments.isEmpty {
        throw WisperError.notFound("The recording of this meeting")
      }
      _ = try await update(id) { meeting in
        meeting.status = .processing
        meeting.failure = nil
        if meeting.endedAt == nil { meeting.endedAt = MeetingEngine.end(of: meeting, audio: state.end) }
      }
    } catch {
      processing.remove(id)
      throw error
    }
    if let problem = await finish(id, transcription, directory: directory) { throw problem }
  }

  /// Answers a question using only this meeting's transcript and notes.
  public func ask(_ question: String, about id: Meeting.ID) async throws -> String {
    guard let meeting = try await library.meeting(id) else { throw WisperError.notFound("The meeting") }
    let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty else { return "Ask a question about this meeting." }
    guard !meeting.segments.isEmpty || meeting.notes != nil || !meeting.userNotes.isEmpty else {
      return "This meeting has no transcript or notes yet, so there is nothing to answer from."
    }
    let settings = try await library.settings()
    return try await notes.answer(question, about: meeting, settings: settings)
  }

  /// Call once at launch: meetings left in `.recording` or `.processing` by a
  /// crash or quit are finished from the audio on disk. Returns once they are
  /// marked `.processing`; the work goes on in the background, as after `stop`.
  public func recoverUnfinished() async {
    guard let meetings = try? await library.meetings() else { return }
    let settings = (try? await library.settings()) ?? Settings()
    for meeting in meetings where meeting.status == .recording || meeting.status == .processing {
      let id = meeting.id
      guard !isBusy(id) else { continue }
      processing.insert(id)
      guard let directory = try? await library.audioDirectory(forMeeting: id) else {
        processing.remove(id)
        continue
      }
      let transcription = await makeTranscription(in: directory, settings: settings)
      let audioEnd = await transcription.progress().end
      _ = try? await update(id) { meeting in
        meeting.status = .processing
        if meeting.endedAt == nil { meeting.endedAt = MeetingEngine.end(of: meeting, audio: audioEnd) }
      }
      Task { await self.finish(id, transcription, directory: directory) }
    }
  }

  // MARK: - Inside

  /// Whether this engine is recording or processing the meeting right now.
  private func isBusy(_ id: Meeting.ID) -> Bool {
    live?.meetingID == id || recording?.meetingID == id || startingID == id || processing.contains(id)
  }

  /// Starts capture with system audio when the user wants it, and without it when that fails:
  /// a meeting with only the user's side is better than no meeting.
  private func startCapture(settings: Settings, directory: URL) async throws -> any CaptureSession {
    func request(_ tracks: Set<AudioTrack>) -> CaptureRequest {
      CaptureRequest(
        tracks: tracks,
        microphoneID: settings.microphoneID,
        directory: directory,
        chunkSeconds: tuning.chunkSeconds
      )
    }
    guard settings.meetings.captureSystemAudio else { return try await capture.start(request([.microphone])) }
    do {
      return try await capture.start(request([.microphone, .system]))
    } catch let error as WisperError {
      switch error {
      case .permissionDenied(.systemAudio), .captureFailed:
        let session = try await capture.start(request([.microphone]))
        // Where system audio cannot be recorded at all (iOS) there is nothing for the user to fix.
        if case .permissionDenied = error {
          lastError = "Only your microphone is being recorded. \(error.localizedDescription)"
        }
        return session
      default:
        throw error
      }
    }
  }

  private func makeTranscription(in directory: URL, settings: Settings) async -> MeetingTranscription {
    let words = ((try? await library.words()) ?? []).map(\.text)
    var seen: Set<String> = []
    let vocabulary = (words + [settings.userName])
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    return MeetingTranscription(
      directory: directory,
      transcriber: transcriber,
      options: MeetingTranscription.Options(
        model: settings.transcriptionModel,
        language: settings.language,
        vocabulary: vocabulary,
        concurrency: tuning.concurrency,
        attempts: tuning.attempts,
        retryDelay: tuning.retryDelay
      )
    )
  }

  /// Saves the transcript so far, so an agent reading the library and a crash both see it.
  private func saveLive(_ id: Meeting.ID) async {
    guard let live, live.meetingID == id else { return }
    _ = try? await update(id) { meeting in
      guard meeting.status == .recording else { return }
      meeting.segments = live.segments
    }
  }

  /// Finishes the transcript, writes the notes and saves the meeting as `.ready` or `.failed`.
  /// Returns what went wrong, if anything did. Takes the meeting out of `processing`.
  @discardableResult
  private func finish(
    _ id: Meeting.ID,
    _ transcription: MeetingTranscription,
    directory: URL
  ) async -> WisperError? {
    defer { processing.remove(id) }
    // Chunks that failed while recording get one more round: the connection may be back.
    await transcription.retryUnfinished()
    await transcription.waitUntilIdle()
    let result = await transcription.progress()
    let settings = (try? await library.settings()) ?? Settings()

    var problem: WisperError?
    var failure: String?
    let nothingHeard = result.unfinished > 0 && result.segments.isEmpty
    if result.unfinished > 0 {
      let error = result.error ?? .captureFailed("part of the recording could not be read")
      problem = error
      failure =
        (nothingHeard ? MeetingEngine.transcriptFailed : MeetingEngine.partFailed) + " "
        + error.localizedDescription
    }

    do {
      // The transcript is saved before the notes are asked for, so it is there to read meanwhile.
      let transcribed = try await update(id) { meeting in
        if result.chunkCount > 0 { meeting.segments = result.segments }
        if meeting.endedAt == nil { meeting.endedAt = MeetingEngine.end(of: meeting, audio: result.end) }
      }
      guard let transcribed else {
        // Deleted while it was being processed.
        await transcription.abandon()
        await MeetingEngine.remove(directory)
        return nil
      }

      var draft: MeetingNotesWriter.Draft?
      if !nothingHeard, settings.meetings.autoSummarize, !transcribed.segments.isEmpty {
        do {
          draft = try await notes.write(for: transcribed, settings: settings)
        } catch {
          let error = MeetingEngine.wisperError(error)
          problem = problem ?? error
          failure = failure ?? MeetingEngine.notesFailed + " " + error.localizedDescription
        }
      }

      let finished = try await update(id) { meeting in
        // Set again: someone who saved an older copy of the meeting meanwhile must not undo it.
        if result.chunkCount > 0 { meeting.segments = result.segments }
        meeting.endedAt = transcribed.endedAt
        meeting.status = nothingHeard ? .failed : .ready
        meeting.failure = failure
        if let draft { MeetingEngine.apply(draft, to: &meeting) }
      }
      // The audio goes only when nothing is left that could need it.
      if finished == nil || (failure == nil && !settings.meetings.keepAudio) {
        await MeetingEngine.remove(directory)
      }
    } catch {
      return MeetingEngine.wisperError(error)
    }
    return problem
  }

  /// Applies `change` to the stored meeting and saves it. Working on the stored copy keeps what
  /// the user or an agent changed in the meantime. Returns `nil` when the meeting is gone.
  @discardableResult
  private func update(_ id: Meeting.ID, _ change: (inout Meeting) -> Void) async throws -> Meeting? {
    guard let stored = try await library.meeting(id) else { return nil }
    var meeting = stored
    change(&meeting)
    if meeting != stored { try await library.save(meeting) }
    return meeting
  }

  /// Puts freshly written notes into a meeting. The title is taken only while the meeting
  /// still carries its dated placeholder, so a name the user chose is never replaced.
  private static func apply(_ draft: MeetingNotesWriter.Draft, to meeting: inout Meeting) {
    meeting.notes = draft.notes(keeping: meeting.notes)
    if !draft.title.isEmpty, meeting.title == placeholderTitle(for: meeting.startedAt) {
      meeting.title = draft.title
    }
  }

  private static let transcriptFailed = "This meeting could not be transcribed."
  private static let partFailed = "Part of this meeting could not be transcribed."
  private static let notesFailed = "The notes could not be written."

  /// The title a meeting gets until the notes give it a better one, e.g. "Meeting, 19 Nov, 2:30 PM".
  static func placeholderTitle(for date: Date) -> String {
    let day = date.formatted(.dateTime.day().month(.abbreviated))
    let time = date.formatted(date: .omitted, time: .shortened)
    return "Meeting, \(day), \(time)"
  }

  /// When a meeting that was never stopped properly ended: where its audio or transcript ends.
  private static func end(of meeting: Meeting, audio: TimeInterval) -> Date {
    meeting.startedAt.addingTimeInterval(max(audio, meeting.segments.map(\.end).max() ?? 0))
  }

  private static func wisperError(_ error: any Error) -> WisperError {
    (error as? WisperError) ?? .invalidResponse(error.localizedDescription)
  }

  private static func remove(_ directory: URL) async {
    await Task.detached { _ = try? FileManager.default.removeItem(at: directory) }.value
  }
}
