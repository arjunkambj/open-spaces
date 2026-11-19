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
  /// audio is not allowed or could not be started. Plain English, ready to show. Cleared by the
  /// next start; set it to `nil` to dismiss it.
  public var lastError: String?

  /// Length of one audio chunk, in seconds. Long enough to give the transcriber context, short
  /// enough that the live transcript moves and a crash loses little.
  private static let chunkSeconds: TimeInterval = 30
  /// The shortest time between two saves of the transcript while recording.
  private static let liveSaveInterval: Duration = .seconds(5)

  /// Whether this kind of device can record what other apps play: a Mac can, an iPhone or
  /// iPad cannot. Where it cannot, the engine does not ask for it, and has nothing to tell
  /// the user about it.
  private static var recordsSystemAudio: Bool {
    #if os(macOS)
      true
    #else
      false
    #endif
  }

  /// A meeting the engine is working on, as it last saw it, and where its audio is.
  private struct Held {
    var meeting: Meeting
    var directory: URL
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
  @ObservationIgnored private var recording: Recording?
  @ObservationIgnored private var isStarting = false
  /// The meeting `start` is setting up, before `live` is set.
  @ObservationIgnored private var startingID: Meeting.ID?
  /// The meetings being recorded or processed. See `update`.
  @ObservationIgnored private var held: [Meeting.ID: Held] = [:]

  public init(
    library: any Library,
    capture: any AudioCapture,
    transcriber: any Transcriber,
    languageModel: any LanguageModel
  ) {
    self.library = library
    self.capture = capture
    self.transcriber = transcriber
    notes = MeetingNotesWriter(languageModel: languageModel)
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
    let options = try await transcriptionOptions(settings)
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

    held[id] = Held(meeting: meeting, directory: directory)
    let transcription = MeetingTranscription(directory: directory, transcriber: transcriber, options: options)
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
    let saver = Task { [weak self] in
      for await _ in saveRequests {
        await self?.saveLive(id)
        try? await Task.sleep(for: MeetingEngine.liveSaveInterval)
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
        self.release(id)
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
    guard let saved else { throw WisperError.notFound("The meeting") }
    // The notes were the last thing missing, so the audio may have done its job now.
    if saved.status == .ready, saved.failure == nil { await settleAudio(of: id, settings: settings) }
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
      held[id] = Held(meeting: meeting, directory: directory)
      transcription = try await resumeTranscription(in: directory, settings: settings)
      let state = await transcription.progress()
      // Nothing is missing, or what is missing is gone for good and the meeting says so.
      let isSettled = meeting.failure == nil || meeting.failure == MeetingEngine.partLost
      if meeting.status == .ready, isSettled, state.unfinished == 0 {
        release(id)
        return
      }
      if state.chunkCount == 0, meeting.status == .failed, meeting.segments.isEmpty {
        throw WisperError.notFound("The recording of this meeting")
      }
      _ = try await update(id) { meeting in
        meeting.status = .processing
        // A part that is gone for good stays gone, whatever this try brings.
        if meeting.failure != MeetingEngine.partLost { meeting.failure = nil }
        if meeting.endedAt == nil { meeting.endedAt = MeetingEngine.end(of: meeting, audio: state.end) }
      }
    } catch {
      release(id)
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
    guard let meetings = try? await library.meetings(), let settings = try? await library.settings()
    else { return }
    for meeting in meetings where meeting.status == .recording || meeting.status == .processing {
      let id = meeting.id
      guard !isBusy(id) else { continue }
      processing.insert(id)
      guard let directory = try? await library.audioDirectory(forMeeting: id),
        let transcription = try? await resumeTranscription(in: directory, settings: settings)
      else {
        processing.remove(id)
        continue
      }
      held[id] = Held(meeting: meeting, directory: directory)
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

  /// Takes the meeting off the list of those being worked on.
  private func release(_ id: Meeting.ID) {
    processing.remove(id)
    held[id] = nil
  }

  /// Starts capture with system audio when the user wants it, and without it when that fails:
  /// a meeting with only the user's side is better than no meeting, as long as the user knows.
  private func startCapture(settings: Settings, directory: URL) async throws -> any CaptureSession {
    func request(_ tracks: Set<AudioTrack>) -> CaptureRequest {
      CaptureRequest(
        tracks: tracks,
        microphoneID: settings.microphoneID,
        directory: directory,
        chunkSeconds: MeetingEngine.chunkSeconds
      )
    }
    // Where system audio cannot be recorded at all there is nothing to try, and nothing to tell.
    guard settings.meetings.captureSystemAudio, MeetingEngine.recordsSystemAudio else {
      return try await capture.start(request([.microphone]))
    }
    do {
      return try await capture.start(request([.microphone, .system]))
    } catch let error as WisperError {
      let reason: String
      switch error {
      case .permissionDenied(.systemAudio): reason = error.localizedDescription
      case .captureFailed(let detail): reason = detail
      default: throw error
      }
      // When it was the microphone that failed, this throws and the meeting does not start.
      let session = try await capture.start(request([.microphone]))
      lastError = "Only your microphone is being recorded. \(reason)"
      return session
    }
  }

  /// The transcript of a meeting an earlier run or an earlier try left unfinished, picked up
  /// from the audio in its folder.
  private func resumeTranscription(
    in directory: URL,
    settings: Settings
  ) async throws -> MeetingTranscription {
    await MeetingTranscription.resuming(
      in: directory,
      transcriber: transcriber,
      options: try await transcriptionOptions(settings)
    )
  }

  private func transcriptionOptions(_ settings: Settings) async throws -> MeetingTranscription.Options {
    let words = try await library.words().map(\.text)
    var seen: Set<String> = []
    let vocabulary = (words + [settings.userName])
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    return MeetingTranscription.Options(
      model: settings.transcriptionModel,
      language: settings.language,
      vocabulary: vocabulary
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
    defer { release(id) }
    // Chunks that failed while recording get one more round: the connection may be back.
    await transcription.retryUnfinished()
    await transcription.waitUntilIdle()
    let result = await transcription.progress()

    var problem: WisperError?
    do {
      let settings = try await library.settings()
      var failure: String?
      let nothingHeard = result.unfinished > 0 && result.segments.isEmpty
      if result.unfinished > 0 {
        let error = result.error ?? .captureFailed("part of the recording could not be read")
        problem = error
        failure =
          (nothingHeard ? MeetingEngine.transcriptFailed : MeetingEngine.partFailed) + " "
          + MeetingEngine.words(for: error, settings)
      }

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
          failure = failure ?? MeetingEngine.notesFailed + " " + MeetingEngine.words(for: error, settings)
        }
      }

      // What can still be put right is said first. What is gone for good is said after that,
      // and stays: nothing will bring that part back.
      let lost = result.lostAudio || transcribed.failure == MeetingEngine.partLost
      let (finalFailure, finalDraft) = (failure ?? (lost ? MeetingEngine.partLost : nil), draft)
      let finished = try await update(id) { meeting in
        // Set again: someone who saved an older copy of the meeting meanwhile must not undo it.
        if result.chunkCount > 0 { meeting.segments = result.segments }
        meeting.endedAt = transcribed.endedAt
        meeting.status = nothingHeard ? .failed : .ready
        meeting.failure = finalFailure
        if let finalDraft { MeetingEngine.apply(finalDraft, to: &meeting) }
      }
      // The audio goes when the meeting is deleted, or when all of it was transcribed, nothing
      // is left that could need it and the user does not keep audio. Never otherwise.
      if finished == nil || (failure == nil && result.unfinished == 0 && !settings.meetings.keepAudio) {
        await MeetingEngine.remove(directory)
      }
    } catch {
      let error = MeetingEngine.wisperError(error)
      // The outcome could not be saved. One more try, at saying so: left as it is, the meeting
      // would look busy until the app is opened the next time. The audio stays for a retry.
      _ = try? await update(id) { meeting in
        meeting.status = .failed
        meeting.failure = MeetingEngine.notSaved + " " + error.localizedDescription
      }
      return error
    }
    return problem
  }

  /// For a meeting that has just become complete outside `finish`: removes its audio when the
  /// user does not keep audio and every part of it was transcribed, and passes on what the audio
  /// folder knows about a part that was lost.
  private func settleAudio(of id: Meeting.ID, settings: Settings) async {
    guard let directory = try? await library.audioDirectory(forMeeting: id) else { return }
    let audio = await Task.detached { MeetingManifest.load(from: directory) }.value
    if audio.lostAudio == true {
      _ = try? await library.updateMeeting(id) { meeting in
        if meeting.failure == nil { meeting.failure = MeetingEngine.partLost }
      }
    }
    guard !settings.meetings.keepAudio, audio.chunks.allSatisfy({ $0.state == .done }) else {
      // Asking for the folder made it, if the audio had gone before. An empty one is not left.
      rmdir(directory.path)
      return
    }
    await MeetingEngine.remove(directory)
  }

  /// Applies `change` to the stored meeting and saves it. Working on the stored copy keeps what
  /// the user or an agent changed in the meantime. Returns `nil` when the meeting was deleted.
  ///
  /// "The library has no such meeting" is not proof of a delete: a `meeting.json` that cannot
  /// be read is moved aside by the library and reads as missing too. Only a meeting whose
  /// folder is gone, or holds no `meeting.json` of any kind, was deleted. Any other meeting
  /// the engine is working on is written back from what the engine last saw of it, so its
  /// audio is never taken for the audio of a deleted meeting.
  @discardableResult
  private func update(
    _ id: Meeting.ID,
    _ change: @Sendable (inout Meeting) -> Void
  ) async throws -> Meeting? {
    if let saved = try await library.updateMeeting(id, change) {
      held[id]?.meeting = saved
      return saved
    }
    guard let kept = held[id], await !MeetingEngine.wasDeleted(audio: kept.directory) else { return nil }
    var meeting = kept.meeting
    change(&meeting)
    try await library.save(meeting)
    held[id]?.meeting = meeting
    return meeting
  }

  /// Puts freshly written notes into a meeting. The title is taken only while the meeting
  /// still carries its dated placeholder, so a name the user chose is never replaced.
  private nonisolated static func apply(_ draft: MeetingNotesWriter.Draft, to meeting: inout Meeting) {
    meeting.notes = draft.notes(keeping: meeting.notes)
    if !draft.title.isEmpty, meeting.title == placeholderTitle(for: meeting.startedAt) {
      meeting.title = draft.title
    }
  }

  private static let transcriptFailed = "This meeting could not be transcribed."
  private static let partFailed = "Part of this meeting could not be transcribed."
  private nonisolated static let notesFailed = "The notes could not be written."
  private nonisolated static let notSaved = "This meeting could not be saved."
  /// What a meeting says when part of its audio is gone for good.
  nonisolated static let partLost =
    "The app closed while this meeting was being recorded. The last part could not be saved."

  /// Whether `retry` could improve this meeting. False when it has no problem,
  /// and when what it lost is gone for good: screens should then show the
  /// message without a "Try again" button.
  public nonisolated static func canRetry(_ meeting: Meeting) -> Bool {
    guard let failure = meeting.failure else { return meeting.status == .failed }
    return failure != partLost
  }

  /// The title a meeting gets until the notes give it a better one, e.g. "Meeting, 19 Nov, 2:30 PM".
  nonisolated static func placeholderTitle(for date: Date) -> String {
    let day = date.formatted(.dateTime.day().month(.abbreviated))
    let time = date.formatted(date: .omitted, time: .shortened)
    return "Meeting, \(day), \(time)"
  }

  /// When a meeting that was never stopped properly ended: where its audio or transcript ends.
  private nonisolated static func end(of meeting: Meeting, audio: TimeInterval) -> Date {
    meeting.startedAt.addingTimeInterval(max(audio, meeting.segments.map(\.end).max() ?? 0))
  }

  /// The message for a failed request, naming the user's own server when one is set.
  private nonisolated static func words(for error: WisperError, _ settings: Settings) -> String {
    guard let server = try? settings.apiServer() else { return error.localizedDescription }
    return error.message(server: server)
  }

  private static func wisperError(_ error: any Error) -> WisperError {
    (error as? WisperError) ?? .invalidResponse(error.localizedDescription)
  }

  private static func remove(_ directory: URL) async {
    await Task.detached { _ = try? FileManager.default.removeItem(at: directory) }.value
  }

  /// Whether the meeting whose audio folder is `directory` was deleted: the folder the audio
  /// folder sits in is gone, or has no `meeting.json` in it, not even one that was moved aside
  /// as unreadable (`meeting.json.corrupt-…`). See `docs/data-format.md` for the layout.
  private static func wasDeleted(audio directory: URL) async -> Bool {
    await Task.detached {
      let folder = directory.deletingLastPathComponent()
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return true }
      return !names.contains { $0.hasPrefix("meeting.json") }
    }.value
  }
}
