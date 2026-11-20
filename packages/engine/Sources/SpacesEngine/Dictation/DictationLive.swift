import Foundation
import SpacesDomain

/// The live side of one recording: a session with the live transcriber, fed with the sound as
/// it is captured, so the text is (nearly) ready when the person stops speaking.
///
/// It is an extra, never the only copy: the recording is written to its file all the same.
/// Whenever the live side cannot be trusted (`text` returns `nil`), the file is transcribed.
struct LiveTake: Sendable {
  /// A session that has been handed all the sound there was.
  private struct Fed: Sendable {
    var session: any LiveTranscription
    /// How much sound it was handed, in seconds.
    var seconds: TimeInterval
  }

  /// The session, once it is open. `nil` when it could not be opened.
  let opening: Task<(any LiveTranscription)?, Never>
  private let feeding: Task<Fed?, Never>

  /// How far the sound handed over may differ from the length of the file, in seconds, and
  /// still count as all of it.
  static let tolerance: TimeInterval = 0.3

  /// Opens a session and feeds it the sound of `capture` until that ends.
  ///
  /// Nothing is opened while the server address in the settings cannot be used.
  init(
    transcriber: any LiveTranscriber,
    library: any Library,
    capture: Task<Result<any CaptureSession, any Error>, Never>
  ) {
    let opening = Task { () -> (any LiveTranscription)? in
      guard let settings = try? await library.settings(), (try? settings.apiServer()) != nil,
        let words = try? await library.words()
      else { return nil }
      let request = LiveTranscriptionRequest(
        model: settings.transcriptionModel,
        language: DictationPipeline.clean(settings.language),
        vocabulary: DictationPipeline.unique(words.map(\.text) + [settings.userName])
      )
      let session = try? await transcriber.open(request)
      if Task.isCancelled {
        session?.cancel()
        return nil
      }
      return session
    }
    self.opening = opening
    feeding = Task { () -> Fed? in
      let session = await opening.value
      guard case .success(let recording) = await capture.value else {
        session?.cancel()
        return nil
      }
      guard let session else {
        // Nobody wants the sound. Read it anyway, so it does not pile up while the recording runs.
        for await _ in recording.frames {}
        return nil
      }
      var seconds: TimeInterval = 0
      // Sound captured before the session opened waited in the stream. Nothing is skipped.
      for await frames in recording.frames {
        session.send(frames)
        if frames.sampleRate > 0 { seconds += Double(frames.samples.count) / frames.sampleRate }
      }
      if Task.isCancelled {
        session.cancel()
        return nil
      }
      return Fed(session: session, seconds: seconds)
    }
  }

  /// The text of the recording, or `nil` when the live side cannot answer for all of it: no
  /// session could be opened, sound went missing on the way, or the session failed.
  ///
  /// - Parameter duration: the length of the recorded file, in seconds.
  func text(ofRecording duration: TimeInterval) async -> Transcript? {
    guard let fed = await feeding.value else { return nil }
    // Sound that never reached the session cannot be in its text.
    guard abs(fed.seconds - duration) <= LiveTake.tolerance else {
      fed.session.cancel()
      return nil
    }
    return try? await fed.session.finish()
  }

  /// Whether the session is open, waiting at most `seconds` for it. A session that failed to
  /// open is "not open" right away.
  func isOpen(within seconds: TimeInterval) async -> Bool {
    let opening = opening
    let (answers, feed) = AsyncStream.makeStream(of: Bool.self)
    let asking = Task { feed.yield(await opening.value != nil) }
    let timer = Task {
      try? await Task.sleep(for: .seconds(seconds))
      feed.yield(false)
    }
    defer {
      asking.cancel()
      timer.cancel()
    }
    for await answer in answers { return answer }
    return false
  }

  /// Ends the session, whatever state it is in. Safe to call more than once, and after `text`.
  func cancel() {
    opening.cancel()
    feeding.cancel()
    let opening = opening
    Task { await opening.value?.cancel() }
  }
}

extension DictationPipeline {
  /// How long the live side is given before the file is sent as well: time for the last of
  /// the sound to arrive and be written out, which grows a little with the recording.
  static func liveHeadStart(forRecording duration: TimeInterval) -> TimeInterval {
    min(6, 1.5 + 0.1 * max(0, duration))
  }

  /// How long a session that is still being opened when the person stops speaking is waited
  /// for. It has heard nothing yet, so it has no lead over the file worth waiting for.
  static let liveOpeningGrace: TimeInterval = 0.3

  /// The words of a recording, from the live session when it has them, and from the file
  /// otherwise.
  ///
  /// The live side goes first. The file is sent when the live side fails, when it says nobody
  /// spoke (a recording is never thrown away on its word alone), when its session is still
  /// not open, or when it has not answered after its head start. From then on, whichever
  /// answers first is used.
  func heard(
    _ request: TranscriptionRequest,
    live: LiveTake?,
    duration: TimeInterval
  ) async throws -> (transcript: Transcript, path: Dictation.Timing.Path) {
    guard let live else { return (try await transcriber.transcribe(request), .file) }

    enum Answer: Sendable {
      case live(Transcript?)
      case file(Result<Transcript, any Error>)
      case headStartOver
    }
    let transcriber = transcriber
    let (answers, feed) = AsyncStream.makeStream(of: Answer.self)
    let listening = Task { feed.yield(.live(await live.text(ofRecording: duration))) }
    let timer = Task {
      if await live.isOpen(within: Self.liveOpeningGrace) {
        try? await Task.sleep(for: .seconds(Self.liveHeadStart(forRecording: duration)))
      }
      feed.yield(.headStartOver)
    }
    var uploading: Task<Void, Never>?
    defer {
      listening.cancel()
      timer.cancel()
      uploading?.cancel()
      live.cancel()
    }
    var liveIsOut = false
    var fileFailure: (any Error)?
    for await answer in answers {
      switch answer {
      case .live(let transcript?)
      where !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
        return (transcript, .live)
      case .live:
        liveIsOut = true
        if let fileFailure { throw fileFailure }
      case .headStartOver:
        break
      case .file(.success(let transcript)):
        return (transcript, .file)
      case .file(.failure(let error)):
        // The live side may still have it.
        if liveIsOut { throw error }
        fileFailure = error
      }
      if uploading == nil {
        uploading = Task { [request] in
          do {
            feed.yield(.file(.success(try await transcriber.transcribe(request))))
          } catch {
            feed.yield(.file(.failure(error)))
          }
        }
      }
    }
    // The stream only ends early when this task was cancelled.
    throw CancellationError()
  }
}
